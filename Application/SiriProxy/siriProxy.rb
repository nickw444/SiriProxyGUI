#!/usr/bin/env ruby
require 'rubygems'
require 'eventmachine'
require 'zlib'
require 'cfpropertylist'
require 'pp'
require 'tweakSiri'
require 'interpretSiri'

LOG_LEVEL = 1

class String
	def to_hex(seperator=" ")
		self.bytes.to_a.map{|i| i.to_s(16).rjust(2, '0')}.join(seperator)
	end
end


class SiriProxyConnection < EventMachine::Connection
	include EventMachine::Protocols::LineText2
	
	attr_accessor :otherConnection, :name, :ssled, :outputBuffer, :inputBuffer, :processedHeaders, :unzipStream, :zipStream, :consumedAce, :unzippedInput, :unzippedOutput, :lastRefId, :pluginManager, :is_4S, :sessionValidationData, :speechId, :assistantId, :aceId,:log,:log, :speechId_avail, :assistantId_avail, :validationData_avail

	def lastRefId=(refId)
		@lastRefId = refId
		self.otherConnection.lastRefId = refId if self.otherConnection.lastRefId != refId
	end
	
	#######################
	#ReadSavedData
	def get_speechId
	    begin
		File.open("speechId", "r") {|file| self.speechId = file.read}
		self.speechId_avail = true
	    rescue SystemCallError
		puts "[ERROR - SiriProy] Error opening the speechId file. Connect an iPhone4S first or create them manually!"
		writelog("[ERROR - SiriProy] Error opening the speechId file. Connect an iPhone4S first or create them manually!")
	    end
	end

	def get_assistantId
	    begin
		File.open("assistantId", "r") {|file| self.assistantId = file.read}
		self.assistantId_avail = true
	    rescue SystemCallError
		puts "[ERROR - SiriProxy] Error opening the assistantId file. Connect an iPhone4S first or create them manually!"
		writelog("[ERROR - SiriProxy] Error opening the assistantId file. Connect an iPhone4S first or create them manually!")
	    end
	end

	def get_validationData
	    begin
		File.open("sessionValidationData", "rb") {|file| self.sessionValidationData = file.read}
		self.validationData_avail = true
	    rescue SystemCallError
		puts "[ERROR - SiriProxy] Error opening the sessionValidationData  file. Connect an iPhone4S first or create them manually!"
		writelog("[ERROR - SiriProxy] Error opening the sessionValidationData  file. Connect an iPhone4S first or create them manually!")
	    end
	end  

	def initialize
		super
		self.processedHeaders = false
		self.outputBuffer = ""
		self.inputBuffer = ""
		self.unzippedInput = ""
		self.unzippedOutput = ""
		self.unzipStream = Zlib::Inflate.new
		self.zipStream = Zlib::Deflate.new
		self.consumedAce = false
		self.is_4S = false 			#bool if its iPhone 4S
		self.sessionValidationData = nil	#validationData
		self.speechId = nil			#speechID
		self.assistantId = nil			#assistantID
		self.speechId_avail = false		#speechID available
		self.assistantId_avail = false		#assistantId available
		self.validationData_avail = false	#validationData available
	end
	
	def plist_blob(string)
	string = [string].pack('H*')
	#string = [string]
	string.blob = true
	string
	end
	
	def post_init
		self.ssled = false
	end

	def ssl_handshake_completed
		self.ssled = true
		
		puts "[Info - #{self.name}] SSL completed for #{self.name}" if LOG_LEVEL > 1
		writelog("[Info - #{self.name}] SSL completed for #{self.name}") if LOG_LEVEL > 1
	end
	
	def receive_line(line) #Process header
		putsputs "[Header - #{self.name}] #{line}" if LOG_LEVEL > 2
		writelog("[Header - #{self.name}] #{line}") if LOG_LEVEL > 2 #not sure about this one
		
		if(line == "") #empty line indicates end of headers
			puts "[Debug - #{self.name}] Found end of headers" if LOG_LEVEL > 3
			writelog("[Debug - #{self.name}] Found end of headers") if LOG_LEVEL > 3
			self.set_binary_mode
			self.processedHeaders = true
		##############
		#Check for User Agent
		elsif line.match(/^User-Agent:/)
			if line.match(/iPhone4,1;/)
				puts "[Info - SiriProxy] iPhone 4S connected"
				writelog("[Info - SiriProxy] iPhone 4S connected")
				self.is_4S = true
			else
				puts "[Info - SiriProxy] - iPhone 4 or other non 4S connected. Using saved keys"
				self.is_4S = false
				writelog("[Info - SiriProxy] - iPhone 4 or other non 4S connected. Using saved keys")
				#maybe change header... but not for now
				#puts "[Info - changed header] " + line
				#line["iPhone3,1"] = "iPhone4,1")
			end
		end
		
		self.outputBuffer << (line + "\x0d\x0a") #Restore the CR-LF to the end of the line
		
		flush_output_buffer()
	end

	def receive_binary_data(data)
		self.inputBuffer << data
		
		##Consume the "0xAACCEE02" data at the start of the stream if necessary (by forwarding it to the output buffer)
		if(self.consumedAce == false)
			self.outputBuffer << self.inputBuffer[0..3]
			self.inputBuffer = self.inputBuffer[4..-1]
			self.consumedAce = true;
		end
		
		process_compressed_data()
		
		flush_output_buffer()
	end
	
	def flush_output_buffer
		return if self.outputBuffer.empty?
	
		if(self.otherConnection.ssled)
			puts "[Debug - #{self.name}] Forwarding #{self.outputBuffer.length} bytes of data to #{self.otherConnection.name}" if LOG_LEVEL > 5
			writelog("[Debug - #{self.name}] Forwarding #{self.outputBuffer.length} bytes of data to #{self.otherConnection.name}") if LOG_LEVEL > 5
			#puts  self.outputBuffer.to_hex if LOG_LEVEL > 5
			self.otherConnection.send_data(self.outputBuffer)
			self.outputBuffer = ""
		else
			puts "[Debug - #{self.name}] Buffering some data for later (#{self.outputBuffer.length} bytes buffered)" if LOG_LEVEL > 5
			writelog("[Debug - #{self.name}] Buffering some data for later (#{self.outputBuffer.length} bytes buffered)") if LOG_LEVEL > 5
			#puts  self.outputBuffer.to_hex if LOG_LEVEL > 5
		end
	end

  def checkHave4SData
     if self.speechId != nil and self.assistantId != nil and self.sessionValidationData != nil

        #writing keys
        File.open("speechId","w") do |file|
           file.write(self.speechId)
        end
        File.open("assistantId","w") do |file|
           file.write(self.assistantId)
        end
        File.open("sessionValidationData","wb") do |file|
	file.write(self.sessionValidationData)
	#file.write("".unpack('H*').join(""))
        end
        puts "[Info - SiriProxy] Keys written to file"
		writelog("[Info - SiriProxy] Keys written to file")
     end
  end

	def process_compressed_data		
		self.unzippedInput << self.unzipStream.inflate(self.inputBuffer)
		self.inputBuffer = ""
		puts "========UNZIPPED DATA (from #{self.name} =========" if LOG_LEVEL > 5
		puts self.unzippedInput.to_hex if LOG_LEVEL > 5
		puts "==================================================" if LOG_LEVEL > 5
		
		while(self.has_next_object?)
			object = read_next_object_from_unzipped()
			
			if(object != nil) #will be nil if the next object is a ping/pong
				new_object = prep_received_object(object) #give the world a chance to mess with folks
		
				inject_object_to_output_stream(new_object) if new_object != nil #might be nil if "the world" decides to rid us of the object
			end
		end
	end

	def has_next_object?
		return false if self.unzippedInput.empty? #empty
		unpacked = self.unzippedInput[0...5].unpack('H*').first
		return true if(unpacked.match(/^0[34]/)) #Ping or pong
		
		if unpacked.match(/^[0-9][15-9]/)
      puts "ROGUE PACKET!!! WHAT IS IT?! TELL US!!! IN IRC!! COPY THE STUFF FROM BELOW"
	  writelog("ROGUE PACKET!!! WHAT IS IT?! TELL US!!! IN IRC!! COPY THE STUFF FROM BELOW")
      puts unpacked.to_hex
	  wirtelog(unpacked.to_hex)
		
    end 
    
		objectLength = unpacked.match(/^0200(.{6})/)[1].to_i(16)
		return ((objectLength + 5) < self.unzippedInput.length) #determine if the length of the next object (plus its prefix) is less than the input buffer
	end

	def read_next_object_from_unzipped
		unpacked = self.unzippedInput[0...5].unpack('H*').first
		info = unpacked.match(/^0(.)(.{8})$/)
		
		if(info[1] == "3" || info[1] == "4") #Ping or pong -- just get these out of the way (and log them for good measure)
			object = self.unzippedInput[0...5]
			self.unzippedOutput << object
			
			type = (info[1] == "3") ? "Ping" : "Pong"			
			puts "[#{type} - #{self.name}] (#{info[2].to_i(16)})" if LOG_LEVEL > 3
			writelog("[#{type} - #{self.name}] (#{info[2].to_i(16)})") if LOG_LEVEL > 3
			self.unzippedInput = self.unzippedInput[5..-1]
			
			flush_unzipped_output()
			return nil
		end
	
		object_size = info[2].to_i(16)
		prefix = self.unzippedInput[0...5]
		object_data = self.unzippedInput[5...object_size+5]
		self.unzippedInput = self.unzippedInput[object_size+5..-1]

		parse_object(object_data)
	end
	
	
	def parse_object(object_data)
		plist = CFPropertyList::List.new(:data => object_data)		
		object = CFPropertyList.native_types(plist.value)
		
		object
	end
	
	def inject_object_to_output_stream(object)
		self.lastRefId = object["refId"] if object["refId"] != nil && !object["refId"].empty?
		object_data = object.to_plist(:plist_format => CFPropertyList::List::FORMAT_BINARY)

		#Recalculate the size in case the object gets modified. If new size is 0, then remove the object from the stream entirely
		obj_len = object_data.length
		
		if(obj_len > 0)
			prefix = [(0x0200000000 + obj_len).to_s(16).rjust(10, '0')].pack('H*')
			self.unzippedOutput << prefix + object_data
		end
		
		flush_unzipped_output()
	end
	
	def flush_unzipped_output
		self.zipStream << self.unzippedOutput
		self.unzippedOutput = ""
		self.outputBuffer << self.zipStream.flush
		
		flush_output_buffer()
	end
	##################
	#prepare the recieved object with our data
	def prep_received_object(object)
		if object["properties"] != nil
			if object["properties"]["validationData"] !=nil #&& !object["properties"]["validationData"].empty?
				if self.is_4S
        				puts "[Info - SiriProxy] using iPhone 4S validationData and saving it"
						writelog("[Info - SiriProxy] using iPhone 4S validationData and saving it")
					self.sessionValidationData = object["properties"]["validationData"].unpack('H*').join("")
					checkHave4SData
    				else
    					get_validationData
    					if self.validationData_avail
        					puts "[Info - SiriProxy] using saved validationData"
							writelog("[Info - SiriProxy] using saved validationData")
        					object["properties"]["validationData"] = plist_blob(self.sessionValidationData)
        				else
        					puts "[Info - SiriProxy] no validationData available :("
							writelog("[Info - SiriProxy] no validationData available :(")
        				end
				end
			end
			if object["properties"]["sessionValidationData"] !=nil #&& !object["properties"]["sessionValidationData"].empty?
				if self.is_4S
        				puts "[Info -  SiriProxy] using iPhone 4S validationData and saving it"
						writelog("[Info -  SiriProxy] using iPhone 4S validationData and saving it")
        				self.sessionValidationData = object["properties"]["sessionValidationData"].unpack('H*').join("")
        				checkHave4SData
    				else
    					get_validationData
    					if  self.validationData_avail
        					puts "[Info - SiriProxy] using saved validationData"
							writelog("[Info - SiriProxy] using saved validationData")
        					object["properties"]["sessionValidationData"] = plist_blob(self.sessionValidationData)
        				else
        					puts "[Info - SiriProxy] no validationData available :("
							writelog("[Info - SiriProxy] no validationData available :(")
        				end
    				end
			end
			if object["properties"]["speechId"] !=nil #&& !object["properties"]["speechId"].empty?
				if self.is_4S
					puts "[Info - SiriProxy] using iPhone 4S speechID and saving it"
					writelog("[Info - SiriProxy] using iPhone 4S speechID and saving it")
        				self.speechId = object["properties"]["speechId"]
        				checkHave4SData
				else
					if object["properties"]["speechId"].empty?
						get_speechId
						if speechId_avail
							puts "[Info - SiriProxy] using saved speechID:  #{self.speechId}"
							writelog("[Info - SiriProxy] using saved speechID:  #{self.speechId}")
        						object["properties"]["speechId"] = self.speechId
        					else
        						puts "[Info - SiriProxy] no speechId available :("
								writelog("[Info - SiriProxy] no speechId available :(")
        					end
        				else
        					puts "[Info - SiriProxy] using speechID sent by iPhone: #{object["properties"]["speechId"]}"
							writelog("[Info - SiriProxy] using speechID sent by iPhone: #{object["properties"]["speechId"]}")
        				end
    				end
			end
			if object["properties"]["assistantId"] !=nil #&& !object["properties"]["assistantId"].empty?
				if self.is_4S
					puts "[Info - SiriProxy] using iPhone 4S  assistantId and saving it"
					writelog("[Info - SiriProxy] using iPhone 4S  assistantId and saving it")
					self.assistantId = object["properties"]["assistantId"]
					checkHave4SData
    				else
    					if object["properties"]["assistantId"].empty?
    						get_assistantId
    						if assistantId_avail
        						puts "[Info - SiriProxy] using saved assistantID - #{self.assistantId}"
								writelog("[Info - SiriProxy] using saved assistantID - #{self.assistantId}")
        						object["properties"]["assistantId"] = self.assistantId
        					else
        						puts "[Info - SiriProxy] no assistantId available :("
								writelog("[Info - SiriProxy] no assistantId available :(")
        					end
        				else
        					puts "[Info - SiriProxy] using assistantID sent by iPhone: #{object["properties"]["assistantId"]}"
							writelog("[Info - SiriProxy] using assistantID sent by iPhone: #{object["properties"]["assistantId"]}")
        				end
				end
			end
		end
		puts "[Info - #{self.name}] Object: #{object["class"]}" if LOG_LEVEL == 1
		writelog("[Info - #{self.name}] Object: #{object["class"]}") if LOG_LEVEL == 1

		puts "[Info - #{self.name}] Object: #{object["class"]} (group: #{object["group"]})" if LOG_LEVEL == 2
		puts "[Info - #{self.name}] Object: #{object["class"]} (group: #{object["group"]}, refId: #{object["refId"]}, aceId: #{object["aceId"]})" if LOG_LEVEL > 2
		pp object if LOG_LEVEL > 3
		
		object = received_object(object)
		
		new_obj = object
		object = new_obj if ((new_obj = Interpret.unknown_intent(object, self, self.pluginManager.method(:unknown_command))) != false)		
		object = new_obj if ((new_obj = Interpret.speech_recognized(object, self, self.pluginManager.method(:speech_recognized))) != false)
		
		object
	end
	
	
	#Stub -- override in subclass
	def received_object(object)
	
		object
	end 

end

#####
# This is the connection to the iPhone
#####
class SiriIPhoneConnection < SiriProxyConnection
	def initialize
		super
		self.name = "iPhone"
	end

	def post_init
		super
		start_tls(:cert_chain_file => "server.passless.crt",
				 :private_key_file => "server.passless.key",
				 	  :verify_peer => false)
	end

	def ssl_handshake_completed
		super
		self.otherConnection = EventMachine.connect('guzzoni.apple.com', 443, SiriGuzzoniConnection)
		self.otherConnection.otherConnection = self #hehe
		self.otherConnection.pluginManager = self.pluginManager
	end
	
	def received_object(object)
		self.pluginManager.object_from_client(object, self)
	end
end

#####
# This is the connection to the Guzzoni (the Siri server backend)
#####
class SiriGuzzoniConnection < SiriProxyConnection
	def initialize
		super
		self.name = "Guzzoni"
	end

	def connection_completed
		super
		start_tls(:verify_peer => false)
	end
	
	def received_object(object)		
		self.pluginManager.object_from_guzzoni(object, self)
	end
end

class SiriProxy
	def initialize(pluginClasses=[])
		EventMachine.run do
			EventMachine::start_server('0.0.0.0', 443, SiriIPhoneConnection) { |conn|
				conn.pluginManager = SiriPluginManager.new(
					pluginClasses
				)
			}
	end
	end
end

Interpret = InterpretSiri.new
# Adhosc v1.0
# 'zero configuration OSC message router'
# by Graham Booth, July 2011

require 'rubygems'
require 'dnssd'
require 'osc-ruby'
require 'osc-ruby/em_server'
require 'eventmachine'

class OSC::AddressPattern
#add function to class to allow lookup of the pattern name of an OSC AddressPattern
	def pattern
		@pattern
	end
end
    
class OSC::EMServer
	#overwrite add_method function to add printing to screen
	def add_method(address_pattern, &proc)
      	matcher = OSC::AddressPattern.new( address_pattern )
		puts "Listening to #{matcher.pattern}"
      	@tuples << [matcher, proc]
    end
    
    #add function to class to allow deletion of a namespace (stop monitoring)
	def del_method(namespace)
		patternToDel = OSC::AddressPattern.new(namespace).pattern
		@tuples.each_index do |index|
			address = @tuples[index]
			if address[0].pattern == patternToDel
				@tuples.delete_at(index)
				puts "Stopping listening to #{patternToDel}" # make readable
			end
		end
	end

end

class OSC::Client 
    def initialize(host, port)
    	@host = host
    	@port = port
      	@so = UDPSocket.new
      	@so.connect(host, port)
    end
    
    #replace send function to print 
    def send(mesg)
    	puts ">>> Send: '#{mesg.address} #{mesg.to_a.join(' ')}' to: #{@host} #{@port}"
      	@so.send(mesg.encode, 0)
	end
end

module Registration
# handles all aspects of DNSSD service discovery and storage in registration table

	def self.initialize
		#maxPeers = 20
		#@indexStack = Array.new(maxPeers){|x| (x - (maxPeers - 1)).abs}
		@regTab = []
	end
	
	def self.register(localPlayerName, port)
	# register self as DNSSD service (continuous)
	# localPlayerName comes from Max, as first argument to /connect message
		@localServiceName = nil
		@registrar = DNSSD.register(localPlayerName, "_osc._udp", nil, port) do |register_reply|
		puts "Registering... #{register_reply.name} #{port}"
			@localServiceName = register_reply.name
		end
		sleep(1) until @localServiceName != nil
		return @localServiceName
	end
	
	def self.stopRegistering
	# stop registering self as DNSSD service
		@registrar.stop
	end
	
	def self.discover
	# constantly monitors the network for DNSSD services joining or leaving
	puts "Browsing for services..."
		@browser = DNSSD.browse("_osc._udp") do |browse_reply|
			if (browse_reply.flags.to_i & DNSSD::Flags::Add) != 0
				DNSSD::Service.new.resolve browse_reply do |resolve_reply|
					add(resolve_reply)
					break unless resolve_reply.flags.more_coming?
				end
			else
				remove(browse_reply)
			end
		next if browse_reply.flags.more_coming?
		end
	end
	
	def self.stopDiscovering
	# stop monitoring the network for DNSSD services joining or leaving
		@browser.stop
	end
	
	def self.add(resolve_reply)
	# receive resolve reply, add to registration table
		puts "Adding... #{resolve_reply.name}"
		@regTab << [nil, resolve_reply.name, resolve_reply.target, resolve_reply.port]
		
		sortReorder
		
		p @regTab
				
		# set new index of local player, get new index of joining player
		joinIndex = nil
		@regTab.each do |regData|
			if regData[1] == Local.localName
				Local.localIndex = regData[0]
			end
			if regData[1] == resolve_reply.name
				joinIndex = regData[0]
			end
		end

		# report update, report joining player
		Local.reportUpdate(resolve_reply.name, @regTab)
		Local.reportJoin(joinIndex, resolve_reply.name)

		# print registration table

	end
	
	def self.remove(browse_reply)
	# receive browse reply, delete from registration table
	
		delIndex = nil
		regName = nil
		# match player in table, delete and report leave to local app
		@regTab.each_index do |delIndex|
			regName = @regTab[delIndex][1]
			if browse_reply.name == regName
				puts "Removing... #{regName}"
				@regTab.delete_at(delIndex)
			end	
		end
		
		sortReorder
		
		# set new index of local player
		@regTab.each do |regData|
			if regData[1] == Local.localName
				Local.localIndex = regData[0]
			end
		end
		
		# report udpate to local app
		Local.reportUpdate(browse_reply.name, @regTab)
		Local.reportLeave(delIndex, regName)
		
		# print registration table
		p @regTab	
	end
	
	def self.sortReorder
		# sort into alphabetical order of service name
		@regTab = @regTab.sort_by {|sortData| sortData[1]}
		
		# reorder indices
		@regTab.each_index do |index|
			@regTab[index][0] = index
		end
	end
	
	def self.lookup(service, target)
		# this would be better implemented as additional namespaces e.g. /all /remote etc
		sendTab = []
		case service
			when 'all'
			# picks out all (direct copy)
			sendTab = @regTab
			
			when 'remote'
			# picks out all except self
			sendTab = @regTab.reject{|regData| regData[1] == @localServiceName}
			
			when 'single'
				case target
					when Integer
					# picks out target only (by index)
					sendTab = @regTab.reject{|regData| regData[0] != target}
					
					when String
					# picks out target only (by name)
					sendTab = @regTab.reject{|regData| regData[1] != target}
				end		
		end
		return sendTab
	end
	
end

module Local
# handles all aspects of communication between the Adhosc app and the local app
	
	def self.localName
		@localName
	end

	def self.localIndex
		@localIndex
	end
	
	def self.localIndex= index
		@localIndex = index
	end
	
	def self.serverInit(serverPort, clientPort)
	# initialise local server (listen port specified by command line argument)
		@localserverPort = serverPort
		@localclientPort = clientPort
		puts "Initialising local server on #{@localserverPort}"
		@localServer = OSC::EMServer.new(@localserverPort)
		# set the server running
		Thread.new do
			@localServer.run
		end
	end
	
	def self.listenConnect
	# listens for /connect namespace and calls 'connect' function when received
		Registration.initialize
		@localServer.add_method "/adhosc/local/send/connect" do | incoming |
			incoming = incoming.to_a
			puts ">>> Recv: '/adhosc/local/send/connect #{incoming.join(' ')}'"
			connect(*incoming)
		end
	end
	
	def self.listenConnected
	# listens for /disconnect and /foward namespaces and calls associated functions
	
		# start listening for /disconnect and /forward namespaces
		@localServer.add_method "/adhosc/local/send/disconnect" do | incoming |
			incoming = incoming.to_a
			puts ">>> Recv: '/adhosc/local/send/disconnect #{incoming.join(' ')}'"
			# first disconnect
			disconnect
			# then listen for local /connect message again
			listenConnect
		end
		@localServer.add_method "/adhosc/local/send/forward" do | incoming |
			incoming = incoming.to_a
			puts ">>> Recv: '/adhosc/local/send/forward #{incoming.join(' ')}'"
			Network.forward('single', incoming)
		end
		
		@localServer.add_method "/adhosc/local/send/forward/all" do | incoming |
			incoming = incoming.to_a
			puts ">>> Recv: '/adhosc/local/send/forward/all #{incoming.join(' ')}'"
			Network.forward('all', incoming)
		end
		
		@localServer.add_method "/adhosc/local/send/forward/remote" do | incoming |
			incoming = incoming.to_a
			puts ">>> Recv: '/adhosc/local/send/forward/remote #{incoming.join(' ')}'"
			Network.forward('remote', incoming)
		end
	end
	
	def self.stopListeningConnect
	# remove the required namespaces from the local and net servers (stop monitoring)
		@localServer.del_method "/adhosc/local/send/disconnect"
		@localServer.del_method "/adhosc/local/send/forward"
		@localServer.del_method "/adhosc/local/send/forward/all"
		@localServer.del_method "/adhosc/local/send/forward/remote"
	end
	
	def self.stopListeningConnected
	# stop listening to /connect namespace
		@localServer.del_method "/adhosc/local/send/connect"
	end
	
	def self.connect(playerName, serverPort, clientPort)
		# listen to local namespaces /disconnect /forward and network namespace /forward
		# @localserverPort has already been set by ruby argument
		@localclientPort = clientPort
		Local.stopListeningConnected
		# quit and reinitialise local server, listen to namespaces
		puts "Connecting..."
		# register self as service
		@localName = Registration.register(playerName, @localserverPort)
		Local.listenConnected
		# initialise local client (client port follows server port)
		@localClient = OSC::Client.new('localhost', @localclientPort)
		# send /connected 1 message to local app
		reportConnection(1)
		# start discovering services on the network
		Registration.discover
		Network.listen
	end
	
	def self.disconnect
	# disconnect from the network
		puts "Disconnecting..."
		# stop registering and browsing services
		Registration.stopDiscovering
		Registration.stopRegistering
		# make sure /listpeers bang and /numpeers 0
		@localName = nil
		Local.reportLeave(@localIndex, @localName)
		Local.reportUpdate(@localName, [])
		# stop monitoring namespaces on local and network server
		Local.stopListeningConnect
		Network.stopListeningConnect
		# send /connected 0 message to local app
		reportConnection(0)
	end
	
	def self.forward(incoming)
	# passes /forward messages from LAN to local app -> example message = /pitch 87
		@localClient.send(OSC::Message.new('/adhosc/local/receive/forward', *incoming))
	end
	
	def self.reportConnection(state)
	# report connection state and peer name (to local app)		
		@localClient.send(OSC::Message.new('/adhosc/local/receive/connected', state))
	end	
	
	def self.reportJoin(peerindex, peername)
	# report player joining (to local app)
		@localClient.send(OSC::Message.new('/adhosc/local/receive/joiningpeer', peerindex, peername))		
	end
	
	def self.reportLeave(peerindex, peername)
	# report player leaving (to local app)
		@localClient.send(OSC::Message.new('/adhosc/local/receive/leavingpeer', peerindex, peername))
	end
	
	def self.reportUpdate(peername, table)
	# report local peer, list of peers and number of peers
	# output network status to local application
	# called by AddService or RemoveService or RegStateToLocal

		# build list of service indices and names
		listOfServices = []
		table.each_index do |index|
			listOfServices << table[index][0]
			listOfServices << table[index][1]
		end

		# if local player has just left, send bang as /mypeer
		if @localName == nil
			@localClient.send(OSC::Message.new('/adhosc/local/receive/mypeer'))
		else
			@localClient.send(OSC::Message.new('/adhosc/local/receive/mypeer', @localIndex, @localName))
		end
		
		# send out number of and list of peers
		@localClient.send(OSC::Message.new('/adhosc/local/receive/numpeers', table.size))
		@localClient.send(OSC::Message.new('/adhosc/local/receive/listpeers', *listOfServices))
	
	end
end

module Network
# handles all aspects of communication between the Adhosc app and the local area network

attr_reader :networkserverPort

	def self.serverInit(port)
		# initialise networkServer
		@networkserverPort = port
		puts "Initialising LAN server on #{port}"
		@networkServer = OSC::EMServer.new(port)
		# set the receive server running
		Thread.new do 
			@networkServer.run
		end
	end
	
	def self.stopListeningConnect
		@networkServer.del_method "/adhosc/lan/forward"
	end

	def self.listen
	# listens for /forward namespace from LAN
		@networkServer.add_method "/adhosc/lan/forward" do | incoming |
			incoming = incoming.to_a
			host = incoming.shift
			port = incoming.shift
			puts ">>> Recv: '/adhosc/lan/forward #{incoming.join(' ')}' from: #{host} #{port}"
			Local.forward(incoming)
		end
	end
	
	def self.forward(serviceType, incoming)
	# Passes /forward messages from local app to LAN
	# example message = allRemote /pitch 87.5
		p "forwarding"
		sendTab = Registration.lookup(serviceType, incoming[1])
		sendTab.each do |regData|
			targetIndex = regData[0]
			targetServiceName = regData[1]
			targetLocalName = regData[2]
			targetPort = regData[3]
			newcoming = incoming.dup
			newcoming.insert(1, Local.localIndex, Local.localName)
			forwardClient = OSC::Client.new(targetLocalName, targetPort)
			puts "Forwarding..."
			forwardClient.send(OSC::Message.new('/adhosc/lan/forward', targetLocalName, targetPort, *newcoming)) #first two elements get stripped off at other end
			end
	end
	
end
	
module Adhosc
	# handles opening and closing of the Adhosc app
	
	def self.run
		puts "Adhosc v1.0 // Graham Booth // July 2011"
		# local and network servers are initialised one time only on load
		
		if ARGV[0] == nil
			localserverPort = 9000 # default serverPort
		else
			localserverPort = ARGV[0].to_i
		end
		
		if ARGV[1] == nil
			localclientPort = 9001 # default clientPort
		else
			localclientPort = ARGV[1].to_i
		end

		Local.serverInit(localserverPort, localclientPort)
		Network.serverInit(rand(10000) + 10000)	# assign a random port in the range 10000 - 20000
		# start listening for /connect message
		Local.listenConnect
	end
	
	def self.exit
		exit
	end

end

Adhosc.run

sleep


# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'set'
require 'ipaddr'
require 'protocols/snmp'
require 'aca/trap_dispatcher'

module Cisco; end
module Cisco::Switch; end

# The request rate limiter
load File.join(__dir__, '../meraki_dashboard.rb')

::Orchestrator::DependencyManager.load('Aca::Tracking::SwitchPort', :model, :force)
::Aca::Tracking::SwitchPort.ensure_design_document!

class Cisco::Switch::MerakiSNMP
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'Cisco Meraki IP Snooping'
    generic_name :Snooping
    udp_port 161

    default_settings({
        meraki_api_key: '5ec63c3058acd56b4a4',
        building: 'building_code',
        reserve_time: 5.minutes.to_i,
        snmp_options: {
            version: 'v2c',
            community: 'public',
            timeout: 4
        },
        ignore_macs: {
            "Cisco Phone Dock": "7001b5"
        },
        temporary_macs: {},
        discovery_polling_period: 90
    })

    def on_load
        # flag to indicate if processing is occuring
        @if_mappings = {}
        # @scheduled_status_query = true

        # Interfaces that indicate they have a device connected
        @check_interface = ::Set.new

        # Interfaces that we know are connected to the network
        @connected_interfaces = ::Set.new

        @reserved_interface = ::Set.new
        self[:interfaces] = [] # This will be updated via query

        begin
            on_update

            # Load the current state of the switch from the database
            query = ::Aca::Tracking::SwitchPort.find_by_switch_ip(@remote_address)
            query.each do |detail|
                details = detail.details
                interface = detail.interface
                self[interface] = details

                if details.connected
                    @check_interface << interface
                    @connected_interfaces << interface
                elsif details.reserved
                    @reserved_interface << interface
                end
            end
        rescue => error
            logger.print_error error, 'loading persisted details'
        end

        self[:interfaces] = @connected_interfaces.to_a
        self[:reserved] = @reserved_interface.to_a
    end

    def on_update
        new_client if @resolved_ip
        @remote_address = remote_address.downcase
        @ignore_macs = ::Set.new((setting(:ignore_macs) || {}).values)
        @temporary = ::Set.new((setting(:temporary_macs) || {}).values)
        @polling_period = setting(:discovery_polling_period) || 90

        @meraki_api = ::Cisco::MerakiDashboard.instance
        @api_key = setting(:meraki_api_key)

        self[:name] = @switch_name = setting(:switch_name)
        self[:ip_address] = @remote_address
        self[:building] = setting(:building)
        self[:level] = setting(:level)

        @reserve_time = setting(:reserve_time) || 0
    end

    def on_unload
        if @processing
            client = @client
            @processing.finally { client.close }
        else
            @client&.close
        end
        @client = nil

        td = ::Aca::TrapDispatcher.instance
        td.ignore(@resolved_ip) if @resolved_ip
    end

    def is_processing?
        "IP resolved to #{@resolved_ip}\ntransport online #{!!@client}\nprocessing #{!!@processing}"
    end

    def hostname_resolution(ip)
        td = ::Aca::TrapDispatcher.instance
        td.ignore(@resolved_ip) if @resolved_ip
        @resolved_ip = ip

        logger.debug { "Registering for trap notifications from #{ip}" }
        td.register(thread, logger, ip) { |pdu| check_link_state(pdu) }

        new_client
    end

    def check_link_state(pdu)
        logger.warn "community mismatch: trap #{pdu.community.inspect} != #{@community.inspect}" unless @community == pdu.community

        # Looks like: http://www.alvestrand.no/objectid/1.3.6.1.2.1.2.2.1.html
        # <NETSNMP::PDU:0x007ffed43bb1b0 @version=0, @community="public",
        #   @error_status=0, @error_index=3, @type=4, @varbinds=[
        #       #<NETSNMP::Varbind:0x007ffed43bb048 @oid="1.3.6.1.2.1.2.2.1.1.26", @type=nil, @value=26>, (ifEntry)
        #       #<NETSNMP::Varbind:0x007ffed43bae68 @oid="1.3.6.1.2.1.2.2.1.2.26", @type=nil, @value="GigabitEthernet1/0/19">,
        #       #<NETSNMP::Varbind:0x007ffed43bacb0 @oid="1.3.6.1.2.1.2.2.1.3.26", @type=nil, @value=6>,  (port type 6 == ethernet)
        #       #<NETSNMP::Varbind:0x007ffed43baad0 @oid="1.3.6.1.4.1.9.2.2.1.1.20.26", @type=nil, @value="up">
        #   ], @request_id=1>

        ifIndex = nil
        state = nil
        pdu.varbinds.each do |var|
            oid = var.oid
            # 1.3.6.1.2.1.2.2.1 == ifEntry
            if oid.start_with?('1.3.6.1.2.1.2.2.1.1')
                # port description
                ifIndex = var.value
            elsif oid.start_with?('1.3.6.1.4.1.9.2.2.1.1.20')
                # port state
                state = var.value.to_sym
            end
        end

        if ifIndex && state
            if @processing
                @processing.finally { on_trap(ifIndex, state) }
            else
                on_trap(ifIndex, state)
            end
        end
    end

    # The SNMP trap handler will notify of changes in interface state
    def on_trap(ifIndex, state)
        interface = @if_mappings[ifIndex]
        if interface.nil?
            logger.debug { "Notify: no interface found for #{ifIndex} - #{state}" }
            return
        end

        case state
        when :up
            logger.debug { "Notify Up: #{interface}" }
            remove_reserved(interface)
            @check_interface << interface
            @connected_interfaces << interface
        when :down
            logger.debug { "Notify Down: #{interface}" }
            # We are no longer interested in this interface
            @connected_interfaces.delete(interface)
            @check_interface.delete(interface)
            remove_lookup(interface)
            self[:reserved] = @reserved_interface.to_a
        end

        self[:interfaces] = @connected_interfaces.to_a
    end

    def query_snooping_bindings
        return :not_ready unless @client && @serial
        return :currently_processing if @processing

        logger.debug '==> extracting snooping table <=='

        # See: https://dashboard.meraki.com/api_docs#clients
        entries = @meraki_api.new_request(@api_key, "https://api.meraki.com/api/v0/devices/#{@serial}/clients?timespan=150")
        logger.debug { "found #{entries.length} snooping entries" }

        checked = Set.new
        checked_interfaces = Set.new
        entries.each do |entry|
            interface = @if_mappings[entry[:switchport].to_i]

            next unless @check_interface.include?(interface)
            next if checked_interfaces.include?(interface)
            checked_interfaces << interface

            mac = entry[:mac]
            ip = entry[:ip]
            next unless mac && ip
            mac = mac.gsub(':', '').downcase

            next unless ::IPAddress.valid?(ip)
            next if @ignore_macs.include?(mac[0..5])

            checked << interface

            # NOTE:: Same as snooping_catalyst.rb
            iface = self[interface] || ::Aca::Tracking::StaticDetails.new

            if iface.ip != ip || iface.mac != mac
                logger.debug { "New connection on #{interface} with #{ip}: #{mac}" }

                # NOTE:: Same as username found
                details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                details.connected(mac, @reserve_time, {
                    device_ip: ip,
                    switch_ip: @remote_address,
                    hostname: @hostname,
                    switch_name: @switch_name,
                    interface: interface
                })

                # ip, mac, reserved?, clash?
                self[interface] = details.details

            elsif iface.username.nil?
                username = ::Aca::Tracking::SwitchPort.bucket.get("macuser-#{mac}", quiet: true)
                if username
                    logger.debug { "Found #{username} at #{ip}: #{mac}" }

                    # NOTE:: Same as new connection
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                    details.connected(mac, @reserve_time, {
                        device_ip: ip,
                        switch_ip: @remote_address,
                        hostname: @hostname,
                        switch_name: @switch_name,
                        interface: interface
                    })

                    # ip, mac, reserved?, clash?
                    self[interface] = details.details
                end

            elsif !iface.reserved
                # We don't know the user who is at this desk...
                details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
                reserved = details.check_for_user(@reserve_time)
                self[interface] = details.details if reserved

            elsif iface.clash
                # There was a reservation clash - is there still a clash?
                details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
                details.check_for_user(@reserve_time)
                self[interface] = details.details unless details.clash?
            end
        end

        @connected_interfaces = checked
        self[:interfaces] = checked.to_a
        # @scheduled_status_query = checked.empty?
        (@check_interface - checked).each { |iface| remove_lookup(iface) }
        self[:reserved] = @reserved_interface.to_a

        nil
    end

    # Index short name lookup
    # ifName: 1.3.6.1.2.1.31.1.1.1.1.xx  (where xx is the ifIndex)
    def query_index_mappings
        return :not_ready unless @client
        return :currently_processing if @processing

        logger.debug '==> mapping ifIndex to port names <=='
        @scheduled_if_query = false

        client = @client
        mappings = {}
        serial = nil
        @processing = task do
            client.walk(oid: '1.3.6.1.2.1.31.1.1.1.1').each do |oid_code, value|
                oid_code = oid_code[23..-1]
                mappings[oid_code.to_i] = value.downcase
            end

            # Both 1.3.6.1.2.1.47.1.1.1.1.11.1 and 1.3.6.1.2.1.47.1.1.1.1.11.2000
            # Seem to hold the serial number
            serial = client.get(oid: '1.3.6.1.2.1.47.1.1.1.1.11.1').strip
        end
        @processing.finally {
            @processing = nil
            client.close if client != @client
        }
        @processing.then {
            logger.debug { "<== found #{mappings.length} ports ==>" }
            @serial = self[:serial] = serial if serial
            if mappings.empty?
                @scheduled_if_query = true
            else
                @if_mappings = mappings
            end
        }.value
    end

    # ifOperStatus: 1.3.6.1.2.1.2.2.1.8.xx == up(1), down(2), testing(3)
    def query_interface_status
        return :not_ready unless @client
        return :currently_processing if @processing

        logger.debug '==> querying interface status <=='
        # @scheduled_status_query = false

        client = @client
        if_mappings = @if_mappings
        remove_interfaces = []
        add_interfaces = []
        @processing = task do
            client.walk(oid: '1.3.6.1.2.1.2.2.1.8').each do |oid_code, value|
                oid_code = oid_code[20..-1]
                interface = if_mappings[oid_code.to_i]

                next unless interface

                case value
                when 1 # up
                    next if @check_interface.include?(interface)
                    logger.debug { "Interface Up: #{interface}" }
                    remove_interfaces << interface
                    @check_interface << interface
                when 2 # down
                    next unless @check_interface.include?(interface)
                    logger.debug { "Interface Down: #{interface}" }
                    # We are no longer interested in this interface
                    @check_interface.delete(interface)
                    add_interfaces << interface
                else
                    next
                end
            end
        end
        @processing.finally {
            @processing = nil
            client.close if client != @client
        }
        @processing.then {
            logger.debug '<== finished querying interfaces ==>'
            remove_interfaces.each { |iface| remove_reserved(iface) }
            add_interfaces.each { |iface| remove_lookup(iface) }
            self[:reserved] = @reserved_interface.to_a
        }.value
    end

    def query_connected_devices
        if @processing
            logger.debug 'Skipping device query... busy processing'
            return
        end
        logger.debug 'Querying for connected devices'
        query_index_mappings if @if_mappings.empty? || @scheduled_if_query
        query_interface_status # if @scheduled_status_query
        query_snooping_bindings
        rebuild_client
    rescue => e
        rebuild_client
        # @scheduled_status_query = true
        raise e
    end

    def update_reservations
        check_reservations
    end


    protected


    def new_client
        schedule.clear

        @snmp_settings = setting(:snmp_options).to_h.symbolize_keys
        @snmp_settings[:host] = @resolved_ip
        @community = @snmp_settings[:community]
        rebuild_client

        # Grab the initial state
        next_tick do
            query_connected_devices
        end

        # Connected device polling (in case a trap was dropped by the network)
        # Also expires any desk reservations every 1min
        schedule.every(57000 + rand(5000)) do
            query_connected_devices
            check_reservations if @reserve_time > 0
        end

        # schedule.every('10m') { @scheduled_status_query = true }

        # There is a possibility that these will change on switch reboot
        schedule.every('15m') { @scheduled_if_query = true }
    end

    def rebuild_client
        @client.close if @client && @processing.nil?
        @client = NETSNMP::Client.new(@snmp_settings)
    end

    def received(data, resolve, command)
        logger.error "unexpected response:\n#{data.inspect}"
        :abort
    end

    def remove_lookup(interface)
        # Update the status of the switch port
        model = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
        if model
            # Check if MAC address is black listed.
            # We want to remove the discovery information for the MAC
            # We also need to prevent it being re-discovered for the polling
            # period as the next person to connect will be mis-associated
            # Need to create a database entry for the MAC with a TTL
            mac = model.mac_address
            temporary = if (mac && @temporary.include?(mac[0..5]))
                logger.debug { "removing temporary MAC for #{model.username} with #{model.mac_address} at #{model.desk_id}" }
                @polling_period
            else
                0
            end
            notify = model.disconnected(temporary: temporary)
            details = model.details
            self[interface] = details

            # notify user about reserving their desk
            if notify
                self[:disconnected] = details
                @reserved_interface << interface
            end
        else
            self[interface] = nil
        end
    end

    def remove_reserved(interface)
        return unless @reserved_interface.include? interface
        @reserved_interface.delete interface
        self[:reserved] = @reserved_interface.to_a
    end

    def check_reservations
        remove = []

        # Check if the interfaces are still reserved
        @reserved_interface.each do |interface|
            details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
            remove << interface unless details.reserved?
            self[interface] = details.details
        end

        # Remove them from the reserved list if not
        return unless remove.present?

        @reserved_interface -= remove
        self[:reserved] = @reserved_interface.to_a
    end
end

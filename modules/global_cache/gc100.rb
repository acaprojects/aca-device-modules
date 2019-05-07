module GlobalCache; end

# Documentation: https://aca.im/driver_docs/Global%20Cache/Global%20Cache%20GC-100.pdf

class GlobalCache::Gc100
    include ::Orchestrator::Constants

    # Discovery Information
    tcp_port 4998
    descriptive_name 'GlobalCache IO Gateway'
    generic_name :DigitalIO

    # Communication settings
    tokenize delimiter: "\x0D"

    def on_load
        self[:num_relays] = 0
        self[:num_ir] = 0
    end

    def on_update
    end

    #
    # Config maps the GC100 into a linear set of ir and relays so models can be swapped in and out
    #  config => {:relay => {0 => '2:1',1 => '2:2',2 => '2:3',3 => '3:1'}} etc
    #
    def connected
        @config = nil
        self[:config_indexed] = false
        getdevices

        schedule.every('10s') do
            logger.debug "-- Polling GC100"
            getdevices unless self[:config_indexed]

            do_send("get_NET,0:1", :priority => 0)    # Low priority sent to maintain the connection
        end
    end

    def disconnected
        schedule.clear
    end

    def getdevices
        do_send('getdevices', :max_waits => 100)
    end

    def relay(index, state, options = {})
        if index < self[:num_relays]
            relays = self[:config][:relay] || self[:config][:relaysensor]
            connector = relays[index]
            if is_affirmative?(state)
                state = 1
            else
                state = 0
            end

            do_send("setstate,#{connector},#{state}", options)
        else
            logger.warn "Attempted to set relay on GlobalCache that does not exist: #{index}"
        end
    end

    def ir(index, command, options = {})
        do_send("sendir,1:#{index},#{command}", options)
    end

    def set_ir(index, mode, options = {})
        if index < self[:num_ir]
            connector = self[:config][:ir][index]
            do_send("set_IR,#{connector},#{mode}", options)
        else
            logger.warn "Attempted to set IR mode on GlobalCache that does not exist: #{index}"
        end
    end


    def relay_status?(index, options = {}, &block)
        if index < self[:num_relays]
            connector = self[:config][:relay][index]
            options[:emit] = block if block_given?
            do_send("getstate,#{connector}", options)
        else
            logger.warn "Attempted to check IO on GlobalCache that does not exist: #{index}"
        end
    end

    def io_status?(index, options = {}, &block)
        if index < self[:num_ir]
            connector = self[:config][:ir][index]
            options[:emit] = block if block_given?
            do_send("getstate,#{connector}", options)
        else
            logger.warn "Attempted to check IO on GlobalCache that does not exist: #{index}"
        end
    end

    def received(data, resolve, command)
        logger.debug "GlobalCache sent #{data}"
        data = data.split(',')

        case data[0].to_sym
        when :state, :statechange
            type, index = self[:config][data[1]]
            self["#{type}#{index}"] = data[2] == '1'    # Is relay index on?
        when :device
            address = data[1]
            number, type = data[2].split(' ')        # The response was "device,2,3 RELAY"

            type = type.downcase.to_sym

            value = @config || {}
            value[type] ||= {}
            current = value[type].length

            dev_index = 1
            (current..(current + number.to_i - 1)).each do |index|
                port = "#{address}:#{dev_index}"
                value[type][index] = port
                value[port] = [type, index]
                dev_index += 1
            end
            @config = value

            return :ignore

        when :endlistdevices
            self[:num_relays] = @config[:relay].length unless @config[:relay].nil?
            if @config[:relaysensor]
                @config[:relaysensor][1] = "1:2"
                @config[:relaysensor][2] = "1:3"
                @config[:relaysensor][3] = "1:4"
                self[:num_relays] = @config[:relaysensor].length
            end
            self[:num_ir] = @config[:ir].length unless @config[:ir].nil?
            self[:config] = @config
            @config = nil
            self[:config_indexed] = true

            return :success
        end


        if data.length == 1
            error = case data[0].split(' ')[1].to_i
                when 1 then 'Command was missing the carriage return delimiter'
                when 2 then 'Invalid module address when looking for version'
                when 3 then 'Invalid module address'
                when 4 then 'Invalid connector address'
                when 5 then 'Connector address 1 is set up as "sensor in" when attempting to send an IR command'
                when 6 then 'Connector address 2 is set up as "sensor in" when attempting to send an IR command'
                when 7 then 'Connector address 3 is set up as "sensor in" when attempting to send an IR command'
                when 8 then 'Offset is set to an even transition number, but should be set to an odd transition number in the IR command'
                when 9 then 'Maximum number of transitions exceeded (256 total on/off transitions allowed)'
                when 10 then 'Number of transitions in the IR command is not even (the same number of on and off transitions is required)'
                when 11 then 'Contact closure command sent to a module that is not a relay'
                when 12 then 'Missing carriage return. All commands must end with a carriage return'
                when 13 then 'State was requested of an invalid connector address, or the connector is programmed as IR out and not sensor in.'
                when 14 then 'Command sent to the unit is not supported by the GC-100'
                when 15 then 'Maximum number of IR transitions exceeded'
                when 16 then 'Invalid number of IR transitions (must be an even number)'
                when 21 then 'Attempted to send an IR command to a non-IR module'
                when 23 then 'Command sent is not supported by this type of module'
                else 'Unknown error'
            end
            logger.warn "GlobalCache error: #{error}"
            logger.warn "For command: #{command[:data]}" if command
            return :failed
        end

        return :success
    end

    protected

    def do_send(command, options = {})
        #logger.debug "-- GlobalCache, sending: #{command}"

        command << 0x0D

        send(command, options).catch do |err|
            # Speed up disconnect
            disconnect
            thread.reject(err)
        end
    end
end

require 'digest/md5'

module Panasonic; end
module Panasonic::Projector; end

# Documentation: https://aca.im/driver_docs/Panasonic/panasonic_pt-vw535n_manual.pdf
#  also https://aca.im/driver_docs/Panasonic/pt-ez580_en.pdf

class Panasonic::Projector::Tcp
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 1024
    descriptive_name 'Panasonic Projector'
    generic_name :Display
    default_settings username: 'admin1', password: 'panasonic'

    # Communication settings
    tokenize delimiter: "\r", wait_ready: 'NTCONTROL'
    makebreak!


    # Projector will provide us with a password
    # Which is applied in before_transmit
    before_transmit :apply_password
    wait_response timeout: 5000, retries: 3


    def on_load
        @check_scheduled = false
        self[:power] = false
        self[:stable_state] = true  # Stable by default (allows manual on and off)

        # Meta data for inquiring interfaces
        self[:type] = :projector

        # The projector drops the connection when there is no activity
        schedule.every('60s') do
            if self[:connected]
                power?(priority: 0)
                lamp_hours?(priority: 0)
            end
        end

        on_update
    end

    def on_update
        @username = setting(:username) || 'admin1'
        @password = setting(:password) || 'panasonic'
    end

    def connected
    end

    def disconnected
    end


    COMMANDS = {
        power_on: :PON,
        power_off: :POF,
        power_query: :QPW,
        freeze: :OFZ,
        input: :IIS,
        mute: :OSH,
        lamp: :"Q$S",
        lamp_hours: :"Q$L"
    }
    COMMANDS.merge!(COMMANDS.invert)



    #
    # Power commands
    #
    def power(state, opt = nil)
        self[:stable_state] = false
        if is_affirmative?(state)
            self[:power_target] = On
            do_send(:power_on, retries: 10, name: :power, delay_on_receive: 8000)
            logger.debug "requested to power on"
            do_send(:lamp)
        else
            self[:power_target] = Off
            do_send(:power_off, retries: 10, name: :power, delay_on_receive: 8000).then do
                schedule.in('10s') { do_send(:lamp) }
            end
            logger.debug "requested to power off"
        end
    end

    def power?(**options, &block)
        options[:emit] = block if block_given?
        do_send(:lamp, options)
    end

    def lamp_hours?(**options, &block)
        options[:emit] = block if block_given?
        do_send(:lamp_hours, 1, options)
    end



    #
    # Input selection
    #
    INPUTS = {
        hdmi: :HD1,
        hdmi2: :HD2,
        vga: :RG1,
        vga2: :RG2,
        miracast: :MC1,
        dvi: :DVI,
        displayport: :DP1,
        hdbaset: :DL1,
        composite: :VID
    }
    INPUTS.merge!(INPUTS.invert)


    def switch_to(input)
        input = input.to_sym
        return unless INPUTS.has_key? input

        # Projector doesn't automatically unmute
        unmute if self[:mute]

        do_send(:input, INPUTS[input], retries: 10, delay_on_receive: 2000)
        logger.debug "requested to switch to: #{input}"

        self[:input] = input    # for a responsive UI
    end


    #
    # Mute Audio and Video
    #
    def mute(val = true)
        actual = val ? 1 : 0
        logger.debug "requested to mute"
        do_send(:mute, actual)    # Audio + Video
    end

    def unmute
        logger.debug "requested to unmute"
        do_send(:mute, 0)
    end


    ERRORS = {
        ERR1: '1: Undefined control command',
        ERR2: '2: Out of parameter range',
        ERR3: '3: Busy state or no-acceptable period',
        ERR4: '4: Timeout or no-acceptable period',
        ERR5: '5: Wrong data length',
        ERRA: 'A: Password mismatch',
        ER401: '401: Command cannot be executed',
        ER402: '402: Invalid parameter is sent'
    }


    def received(data, resolve, command)        # Data is default received as a string
        logger.debug { "sent \"#{data}\" for #{command ? command[:data] : 'unknown'}" }

        # This is the ready response
        if data[0] == ' '
            @use_pass = data[1] == '1'
            if @use_pass
                @pass = "#{@username}:#{@password}:#{data[3..-1]}"
                @pass = Digest::MD5.hexdigest(@pass)
            end

            # Ignore this as it is not a response
            return :ignore
        else
            # Error Response
            if data[0] == 'E'
                error = data.to_sym
                self[:last_error] = ERRORS[error]

                # Check for busy or timeout
                if error == :ERR3 || error == :ERR4
                    logger.warn "Proj busy: #{self[:last_error]}"
                    return :retry
                else
                    logger.error "Proj error: #{self[:last_error]}"
                    return :abort
                end
            end

            data = data[2..-1]
            resp = data.split(':')
            cmd = COMMANDS[resp[0].to_sym]
            val = resp[1]

            case cmd
            when :power_on
                self[:power] = true
            when :power_off
                self[:power] = false
            when :power_query
                self[:power] = val.to_i == 1
            when :freeze
                self[:frozen] = val.to_i == 1
            when :input
                self[:input] = INPUTS[val.to_sym]
            when :mute
                self[:mute] = val.to_i == 1
            else
                if command
                    if command[:name] == :lamp
                        ival = resp[0].to_i
                        self[:power] = ival == 1 || ival == 2
                        self[:warming] = ival == 1
                        self[:cooling] = ival == 3

                        if (self[:warming] || self[:cooling]) && !@check_scheduled && !self[:stable_state]
                            @check_scheduled = true
                            schedule.in('13s') do
                                @check_scheduled = false
                                logger.debug "-- checking state"
                                power?(priority: 0) do
                                    state = self[:power]
                                    if state != self[:power_target]
                                        if self[:power_target] || !self[:cooling]
                                            power(self[:power_target])
                                        end
                                    elsif self[:power_target] && self[:cooling]
                                        power(self[:power_target])
                                    else
                                        self[:stable_state] = true
                                        switch_to(self[:input]) if self[:power_target] == On && !self[:input].nil?
                                    end
                                end
                            end
                        end 
                    elsif command[:name] == :lamp_hours
                        # Resp looks like: "001682"
                        self[:lamp_usage] = data.to_i
                    end
                end
            end
        end

        :success
    end


    protected


    def do_send(command, param = nil, **options)
        if param.is_a? Hash
            options = param
            param = nil
        end

        # Default to the command name if name isn't set
        options[:name] = command unless options[:name]

        if param.nil?
            cmd = "00#{COMMANDS[command]}\r"
        else
            cmd = "00#{COMMANDS[command]}:#{param}\r"
        end

        send(cmd, options)
    end

    # Apply the password hash to the command if a password is required
    def apply_password(data)
        if @use_pass
            data = "#{@pass}#{data}"
        end

        return data
    end
end


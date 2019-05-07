module Extron; end

class Extron::Base
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 23

    # Communication settings
    keepalive false
    clear_queue_on_disconnect!

    # This should consume the whole copyright message
    tokenize delimiter: "\r\n", wait_ready: /Copyright.*/i


    def connected
        return if @disable_polling

        if self.respond_to? :do_poll
            schedule.every('1m') do
                logger.debug "Extron Maintaining Connection"
                do_poll
            end
        else
            schedule.every('1m') do
                logger.debug "Extron Maintaining Connection"
                send('Q', :priority => 0, :wait => false)    # Low priority poll to maintain connection
            end
        end

        # Send password if required
        pass = setting(:password)
        if pass.nil?
            device_ready
        else
            do_send(pass)
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        schedule.clear
    end

    def direct(string)
        send(string, :wait => false)
    end


    protected


    def device_ready
        send("I", :wait => true, :command => :information)
        do_send("\e3CV", :wait => true)    # Verbose mode and tagged responses
    end

    def do_send(data, options = {})
        logger.debug { "requesting cmd: #{data} with #{options}" }
        send("#{data}\x0D", options)
    end
end

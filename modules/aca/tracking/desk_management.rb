# frozen_string_literal: true

module Aca; end
module Aca::Tracking; end

# Manual desk tracking will use this DB structure for persistance 
require 'aca/tracking/switch_port'
require 'set'

class Aca::Tracking::DeskManagement
    include ::Orchestrator::Constants



    descriptive_name 'ACA Desk Management'
    generic_name :DeskManagement
    implements :logic

    default_settings({
        mappings: {
            switch_ip: { 'port_id' => 'desk_id' }
        },
        checkin: {
            level_id: []
        },
        timezone: 'Singapore' # used for manual desk checkin
    })

    def on_load
        on_update

        # Load any manual check-in data
        @manual_checkin.each do |level, _|
            logger.debug { "Loading manual desk check-in details for level #{level}" }

            query = ::Aca::Tracking::SwitchPort.find_by_switch_ip(level)
            query.each do |detail|
                details = detail.details
                details[:level] = detail.level
                details[:manual_desk] = true
                details[:clash] = false

                username = details.username
                self[username] = details
                @manual_usage[detail.desk_id] = username
                @manual_users << username
            end
        end

        # Manual checkout times don't need to be checked very often
        cleanup_manual_checkins
        schedule.every('10m') do
            cleanup_manual_checkins
        end

        # Should only call once
        get_usage
    end

    def on_update
        self[:hold_time]    = setting(:desk_hold_time) || 5.minutes.to_i
        self[:reserve_time] = @desk_reserve_time = setting(:desk_reserve_time) || 2.hours.to_i
        @user_identifier = setting(:user_identifier) || :login_name
        @timezone = setting(:timezone) || 'UTC'

        # { "switch_ip": { "port_id": "desk_id" } }
        @switch_mappings = setting(:mappings) || {}
        @desk_mappings = {}
        @switch_mappings.each do |switch_ip, ports|
            ports.each do |port, desk_id|
                @desk_mappings[desk_id] = [switch_ip, port]
            end
        end

        # { level_id: ["desk_id1", "desk_id2", ...] }
        @manual_checkin = setting(:checkin) || {}
        @manual_usage = {} # desk_id => username
        @manual_users = Set.new

        # Bind to all the switches for disconnect notifications
        @subscriptions ||= []
        @subscriptions.each { |ref| unsubscribe(ref) }
        @subscriptions.clear
        subscribe_disconnect
    end

    # Grab the list of desk ids in use on a floor
    #
    # @param level [String] the level id of the floor
    def desk_usage(level)
        (self[level] || []) +
        (self["#{level}:reserved"] || [])
    end

    # Grab the ownership details of the desk
    #
    # @param desk_id [String] the unique id that represents a desk
    def desk_details(desk_id)
        switch_ip, port = @desk_mappings[desk_id]
        if switch_ip
            ::Aca::Tracking::SwitchPort.find_by_id("swport-#{switch_ip}-#{port}")&.details
        else # Check for manual checkin
            username = @manual_usage[desk_id]
            return nil unless username
            self[username]
        end
    end

    # Grabs the current user from the websocket connection
    # If the user has a desk reserved, then they can reserve their desk
    #
    # @param time [Integer] the reserve time in seconds from the unplug time
    # @return [false] if reservation successful
    # @return [true] if reservation failed - timeout had elapsed
    # @return [nil] if manual check-out successful
    # @return [Integer] if there was an error
    #   1: if the username is unknown
    #   2: if there is no reservation to update
    #   3: if the desk ID is unknown for this IP port
    #   4: if reserved by someone else
    def reserve_desk(time = @desk_reserve_time)
        user = current_user
        raise 'User not found' unless user

        username = user.__send__(@user_identifier)
        if username.nil?
            logger.warn "no username defined for #{user.name} (#{user.id})"
            return 1 # no user
        end
        desk_details = self[username]
        return 2 unless desk_details # no reservation to update
        return manual_checkout(desk_details) if desk_details[:manual_desk]

        location = desk_details[:desk_id]
        return 3 unless location # desk ID unknown for this IP port

        switch_ip, port = @desk_mappings[location]
        reservation = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{switch_ip}-#{port}")
        raise "Mapping error. Desk #{location} can't be found on the switch #{switch_ip}-#{port}" unless reservation
        return 4 unless reservation.reserved_by == username # reserved by someone else

        # falsy values == success and truthy values == failure
        !reservation.update_reservation(time)
    end

    # Adjusts the reservation time to 0 - effectively freeing the desk
    def cancel_reservation
        reserve_desk(0)
    end

    # For desks that use sensors or require users to manually reserve
    #
    # @param desk_id [String] the unique id that represents a desk
    # @param level_id [String] the level id of the floor - saves processing if you have it handy
    def manual_checkin(desk_id, level_id = nil)
        raise "desk #{desk_id} does not support manual check-in" unless @manual_desks.include?(desk_id)
        raise "desk #{desk_id} already in use" unless @manual_usage[desk_id].nil?

        # Grab user details if they are available
        username = nil
        user = current_user
        if user
            # Cancel any other desk that has been reserved
            username = user.__send__(@user_identifier)
            cancel_reservation if username.present?
        end

        # Find the level if this was unknown
        if level_id.nil?
            @manual_checkin.each do |level, desks|
                if desks.include? desk_id
                    level_id = level
                    break
                end
            end
        end

        tracker = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{level_id}-#{desk_id}") || ::Aca::Tracking::SwitchPort.new
        tracker.reserved_by = tracker.username = username if username

        # Reserve for the remainder of the day
        Time.zone = @timezone
        now = tracker.unplug_time = Time.now.to_i
        tracker.reserve_time = Time.zone.now.tomorrow.midnight.to_i - now

        # To set the ID correctly
        tracker.level = tracker.switch_ip = level_id
        tracker.desk_id = tracker.interface = desk_id
        tracker.reserved_mac = tracker.mac_address = desk_id
        tracker.save!

        # Update the details to indicate that this is a manual desk
        details = tracker.details
        details[:level] = level_id
        details[:manual_desk] = true
        details[:clash] = false

        # Configure the desk to look occupied on the map
        if username
            @manual_usage[desk_id] = username
            @manual_users << username
            self[username] = details
        else
            # If we don't know the user we just want the desk to look busy
            @manual_usage[desk_id] = desk_id
            self[desk_id] = details
        end
    end

    # For use with sensor systems
    #
    # @param desk_id [String] the unique id that represents a desk
    def force_checkout(desk_id)
        username = @manual_usage[desk_id]
        return unless username
        manual_checkout(self[username])
    end

    protected

    def manual_checkout(details)
        level = details[:level]
        desk_id = details[:desk_id]
        username = details[:username] || desk_id
        
        tracker = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{level}-#{desk_id}")
        tracker&.destroy

        @manual_usage.delete(desk_id)
        @manual_users.delete(username)
        self[username] = nil
    end

    # If people reserve a desk then they may forget to checkout
    #   This cleans up manual reservations when their timeout is expired
    def cleanup_manual_checkins
        remove = []

        @manual_usage.each do |desk_id, username|
            details = self[username]
            remove << details unless details.reserved?
        end

        remove.each do |details|
            manual_checkout(details)
        end
    end

    # Helper to return all the physical switches in a building
    def switches
        system.all(:Snooping)
    end

    # Builds data structures from settings and watches switches for unplug events
    def subscribe_disconnect
        hardware = switches

        # Build the list of desk ids for each level
        desk_ids = {}
        hardware.each do |switch|
            ip = switch[:ip_address]
            mappings = @switch_mappings[ip]
            next unless mappings

            level = switch[:level]
            ids = desk_ids[level] || []
            ids.concat(mappings.values)
            desk_ids[level] = ids
        end

        # Add any manual checkin desks to the data
        @manual_desks = Set.new
        @manual_checkin.each do |level, desks|
            self["#{level}:manual_checkin"] = desks
            ids = desk_ids[level] || []
            ids.concat(desks)
            desk_ids[level] = ids

            # List of all the manual check-in desks
            @manual_desks.merge(desks)
        end

        # Apply the level details
        desk_ids.each { |level, desks|
            self["#{level}:desk_ids"] = desks
            self["#{level}:desk_count"] = desks.length
        }

        # Watch for users unplugging laptops
        sys = system
        (1..hardware.length).each do |index|
            @subscriptions << sys.subscribe(:Snooping, index, :disconnected) do |notify|
                details = notify.value
                if details.reserved_by
                    self[details.reserved_by] = details
                end
            end
        end
    end

    # Schedules periodic desk usage statistics gathering
    def get_usage
        # Get local vars in case they change while we are processing
        all_switches = switches.to_a
        mappings = @switch_mappings
        manual_levels = @manual_checkin.keys

        # Perform operations on the thread pool
        @caching = thread.work {
            level_data = {}

            # Ensure all the manual only levels are included
            manual_levels.each { |level| level_data[level] ||= PortUsage.new([], [], [], [], []) }

            # Find the desks in use
            all_switches.each do |switch|
                apply_mappings(level_data, switch, mappings)
            end

            level_data
        }.then { |levels|
            manual_desk_ids = @manual_usage.keys

            # Apply the settings on thread for performance reasons
            levels.each do |level, desks|
                desks.users.each do |user|
                    username = user.username
                    manual_checkout(self[username]) if @manual_users.include?(username)
                    self[username] = user
                    self[user.reserved_by] = user if user.clash
                end

                desks.reserved_users.each do |user|
                    self[user.reserved_by] = user
                end

                # Map the used manually checked-in desks
                on_level = @manual_checkin[level] || []
                desks.manual = on_level & manual_desk_ids
            end

            # Apply the summaries now manual desk counts are accurate
            levels.each do |level, desks|
                self[level] = desks.inuse + desks.manual
                self["#{level}:clashes"] = desks.clash
                self["#{level}:reserved"] = desks.reserved
                o = self["#{level}:occupied_count"] = desks.inuse.length - desks.clash.length + desks.reserved.length + desks.manual.length
                self["#{level}:free_count"] = self["#{level}:desk_count"] - o
            end

            nil
        }.catch { |error|
            logger.print_error error, 'getting desk usage'
        }.finally {
            schedule.in('5s') { get_usage }
        }
    end

    PortUsage = Struct.new(:inuse, :clash, :reserved, :users, :reserved_users, :manual)

    # Performs the desk usage statistics gathering
    def apply_mappings(level_data, switch, mappings)
        switch_ip = switch[:ip_address]
        map = mappings[switch_ip]
        if map.nil?
            logger.warn "no mappings for switch #{switch_ip}"
            return
        end

        # Grab port information 
        interfaces = switch[:interfaces]
        reservations = switch[:reserved]

        # Build lookup structures
        building = switch[:building]
        level = switch[:level]
        port_usage = level_data[level] ||= PortUsage.new([], [], [], [], [])

        # Prevent needless lookups
        inuse = port_usage.inuse
        clash = port_usage.clash
        reserved = port_usage.reserved
        users = port_usage.users
        reserved_users = port_usage.reserved_users

        # Map the ports to desk IDs
        interfaces.each do |port|
            desk_id = map[port]
            if desk_id
                details = switch[port]
                next unless details

                # Configure desk id if not known
                if details.desk_id != desk_id
                    details.desk_id = desk_id
                    ::User.bucket.subdoc("swport-#{switch_ip}-#{port}") do |doc|
                        doc.dict_upsert(:level, level)
                        doc.dict_upsert(:desk_id, desk_id)
                        doc.dict_upsert(:building, building)
                    end
                end

                inuse << desk_id
                clash << desk_id if details.clash

                # set the user details
                users << details if details.username
            else
                logger.debug { "Unknown port #{port} - no desk mapping found" }
            end
        end

        reservations.each do |port|
            desk_id = map[port]
            if desk_id
                reserved << desk_id

                # set the user details (reserved_by must exist to be here)
                reserved_users << switch[port]
            else
                logger.debug { "Unknown port #{port} - no desk mapping found" }
            end
        end

        nil
    end
end
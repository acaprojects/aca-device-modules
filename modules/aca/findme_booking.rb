# For rounding up to the nearest 15min
# See: http://stackoverflow.com/questions/449271/how-to-round-a-time-down-to-the-nearest-15-minutes-in-ruby
class ActiveSupport::TimeWithZone
    def ceil(seconds = 60)
        return self if seconds.zero?
        Time.at(((self - self.utc_offset).to_f / seconds).ceil * seconds).in_time_zone + self.utc_offset
    end
end


module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::FindmeBooking
    include ::Orchestrator::Constants
    EMAIL_CACHE = ::Concurrent::Map.new
    CAN_LDAP = begin
        require 'net/ldap'
        true
    rescue LoadError
        false
    end
    CAN_EWS = begin
        require 'viewpoint2'
        true
    rescue LoadError
        begin
            require 'viewpoint'
            true
        rescue LoadError
            false
        end
        false
    end


    descriptive_name 'Findme Room Bookings'
    generic_name :Bookings
    implements :logic


    # The room we are interested in
    default_settings({
        update_every: '5m',

        # Moved to System or Zone Setting
        # cancel_meeting_after: 900

        # Card reader IDs if we want to listen for swipe events
        card_readers: ['reader_id_1', 'reader_id_2'],

        # Optional LDAP creds for looking up emails
        ldap_creds: {
            host: 'ldap.org.com',
            port: 636,
            encryption: {
                method: :simple_tls,
                tls_options: {
                    verify_mode: 0
                }
            },
            auth: {
                  method: :simple,
                  username: 'service account',
                  password: 'password'
            }
        },
        tree_base: "ou=User,ou=Accounts,dc=org,dc=com",

        # Optional EWS for creating and removing bookings
        ews_creds: [
            'https://company.com/EWS/Exchange.asmx',
            'service account',
            'password',
            { http_opts: { ssl_verify_mode: 0 } }
        ],
        ews_room: 'room@email.address'
    })


    def on_load
        on_update
    end

    def on_update
        self[:swiped] ||= 0
        @last_swipe_at = 0
        @use_act_as = setting(:use_act_as)

        self[:building] = setting(:building)
        self[:level] = setting(:level)
        self[:room] = setting(:room)
        self[:touch_enabled] = setting(:touch_enabled) || false
        self[:room_name] = setting(:room_name) || system.name

        # Skype join button available 2min before the start of a meeting
        @skype_start_offset = setting(:skype_start_offset) || 120

        # Skype join button not available in the last 8min of a meeting
        @skype_end_offset = setting(:skype_end_offset) || 480

        # Because restarting the modules results in a 'swipe' of the last read card
        ignore_first_swipe = true

        # Is there catering available for this room?
        self[:catering] = setting(:catering_system_id)
        if self[:catering]
            self[:menu] = setting(:menu)
        end

        # Do we want to look up the users email address?
        if CAN_LDAP
            @ldap_creds = setting(:ldap_creds)
            if @ldap_creds
                encrypt = @ldap_creds[:encryption]
                encrypt[:method] = encrypt[:method].to_sym if encrypt && encrypt[:method]
                @tree_base = setting(:tree_base)
                @ldap_user = @ldap_creds.delete :auth
            end
        else
            logger.warn "net/ldap gem not available" if setting(:ldap_creds)
        end

        # Do we want to use exchange web services to manage bookings
        if CAN_EWS
            @ews_creds = setting(:ews_creds)
            @ews_room = (setting(:ews_room) || system.email) if @ews_creds
            # supports: SMTP, PSMTP, SID, UPN (user principle name)
            # NOTE:: Using UPN we might be able to remove the LDAP requirement
            @ews_connect_type = (setting(:ews_connect_type) || :SMTP).to_sym
            @timezone = setting(:room_timezone)
        else
            logger.warn "viewpoint gem not available" if setting(:ews_creds)
        end

        # Load the last known values (persisted to the DB)
        self[:waiter_status] = (setting(:waiter_status) || :idle).to_sym
        self[:waiter_call] = self[:waiter_status] != :idle

        self[:catering_status] = setting(:last_catering_status) || {}
        self[:order_status] = :idle

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)


        # unsubscribe to all swipe IDs if any are subscribed
        if @subs.present?
            @subs.each do |sub|
                unsubscribe(sub)
            end

            @subs = nil
        end

        # Are there any swipe card integrations
        if system.exists? :Security
            readers = setting(:card_readers)
            if readers.present?
                security = system[:Security]

                readers = Array(readers)
                sys = system
                @subs = []
                readers.each do |id|
                    @subs << sys.subscribe(:Security, 1, id.to_s) do |notice|
                        if ignore_first_swipe
                            ignore_first_swipe = false
                        else
                            swipe_occured(notice.value)
                        end
                    end
                end
            end
        end

        fetch_bookings
        schedule.clear
        schedule.every(setting(:update_every) || '5m') { fetch_bookings }
    end


    # ======================================
    # Waiter call information
    # ======================================
    def waiter_call(state)
        status = is_affirmative?(state)

        self[:waiter_call] = status

        # Used to highlight the service button
        if status
            self[:waiter_status] = :pending
        else
            self[:waiter_status] = :idle
        end

        define_setting(:waiter_status, self[:waiter_status])
    end

    def call_acknowledged
        self[:waiter_status] = :accepted
        define_setting(:waiter_status, self[:waiter_status])
    end


    # ======================================
    # Catering Management
    # ======================================
    def catering_status(details)
        self[:catering_status] = details

        # We'll turn off the green light on the waiter call button
        if self[:waiter_status] != :idle && details[:progress] == 'visited'
            self[:waiter_call] = false
            self[:waiter_status] = :idle
            define_setting(:waiter_status, self[:waiter_status])
        end

        define_setting(:last_catering_status, details)
    end

    def commit_order(order_details)
        self[:order_status] = :pending
        status = self[:catering_status]

        if status && status[:progress] == 'visited'
            status = status.dup
            status[:progress] = 'cleaned'
            self[:catering_status] = status
        end

        if self[:catering]
            sys = system
            @oid ||= 1
            systems(self[:catering])[:Orders].add_order({
                id: "#{sys.id}_#{@oid}",
                created_at: Time.now.to_i,
                room_id: sys.id,
                room_name: sys.name,
                order: order_details
            })
        end
    end

    def order_accepted
        self[:order_status] = :accepted
    end

    def order_complete
        self[:order_status] = :idle
    end



    # ======================================
    # ROOM BOOKINGS:
    # ======================================
    def fetch_bookings(*args)
        logger.debug { "looking up todays emails for #{@ews_room}" }
        task {
            todays_bookings
        }.then(proc { |bookings|
            self[:today] = bookings
        }, proc { |e| logger.print_error(e, 'error fetching bookings') })
    end


    # ======================================
    # Meeting Helper Functions
    # ======================================

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        self[:meeting_pending] = meeting_ref
        self[:meeting_ending] = false
        self[:meeting_pending_notice] = false
        define_setting(:last_meeting_started, meeting_ref)
    end

    def cancel_meeting(start_time, *args)
        task {
            if start_time.is_a?(String)
                start_time = start_time.chop
                start_time = Time.parse(start_time).to_i * 1000
            end
            delete_ews_booking (start_time / 1000).to_i
        }.then(proc { |count|
            logger.debug { "successfully removed #{count} bookings" }

            self[:last_meeting_started] = start_time
            self[:meeting_pending] = start_time
            self[:meeting_ending] = false
            self[:meeting_pending_notice] = false
        }, proc { |error|
            logger.print_error error, 'removing ews booking'
        })
    end

    # If last meeting started !== meeting pending then
    #  we'll show a warning on the in room touch panel
    def set_meeting_pending(meeting_ref)
        self[:meeting_ending] = false
        self[:meeting_pending] = meeting_ref
        self[:meeting_pending_notice] = true
    end

    # Meeting ending warning indicator
    # (When meeting_ending !== last_meeting_started then the warning hasn't been cleared)
    # The warning is only displayed when meeting_ending === true
    def set_end_meeting_warning(meeting_ref = nil, extendable = false)
        if self[:last_meeting_started].nil? || self[:meeting_ending] != (meeting_ref || self[:last_meeting_started])
            self[:meeting_ending] = true

            schedule.in('30s') do
                clear_end_meeting_warning
            end

            # Allows meeting ending warnings in all rooms
            self[:last_meeting_started] = meeting_ref if meeting_ref
            self[:meeting_canbe_extended] = extendable
        end
    end

    def clear_end_meeting_warning
        self[:meeting_ending] = self[:last_meeting_started]
    end
    # ---------

    def create_meeting(duration, next_start = nil)
        if next_start
            if next_start.is_a? Integer
                next_start = Time.at((next_start / 1000).to_i)
            else
                next_start = Time.parse(next_start.split(/z/i)[0])
            end
        end

        start_time = Time.now
        end_time = duration.to_i.minutes.from_now.ceil(15.minutes)

        # Make sure we don't overlap the next booking
        if next_start && next_start < end_time
            end_time = next_start
        end

        task {
            make_ews_booking start_time, end_time
        }.then(proc { |id|
            logger.debug { "successfully created booking: #{id}" }
            # We want to start the meeting automatically
            start_meeting(start_time.to_i * 1000)
        }, proc { |error|
            logger.print_error error, 'creating ad hoc booking'
        })
    end


    protected


    def swipe_occured(info)
        # Update the user details
        @last_swipe_at = Time.now.to_i
        self[:fullname] = "#{info[:firstname]} #{info[:lastname]}"
        self[:username] = info[:staff_id]
        email = nil

        if self[:username] && @ldap_creds
            email = EMAIL_CACHE[self[:username]]
            if email
                set_email(email)
                logger.debug { "email #{email} found in cache" }
            else
                # Cache username here as self[:username] might change while we
                #  looking up the previous username
                username = self[:username]

                logger.debug { "looking up email for #{username} - #{self[:fullname]}" }
                task {
                    ldap_lookup_email username
                }.then do |email|
                    if email
                        logger.debug { "email #{email} found in LDAP" }
                        EMAIL_CACHE[username] = email
                        set_email(email)
                    else
                        logger.warn "no email found in LDAP for #{username}"
                        set_email nil
                    end
                end
            end
        else
            logger.warn "no staff ID for user #{self[:fullname]}"
            set_email nil
        end
    rescue => e
        logger.print_error(e, 'error handling card swipe')
    end

    def set_email(email)
        self[:email] = email
        self[:swiped] += 1
    end

    # ====================================
    # LDAP lookup to occur in worker thread
    # ====================================
    def ldap_lookup_email(username)
        ldap = Net::LDAP.new @ldap_creds
        ldap.authenticate @ldap_user[:username], @ldap_user[:password] if @ldap_user

        login_filter = Net::LDAP::Filter.eq('sAMAccountName', username)
        object_filter = Net::LDAP::Filter.eq('objectClass', '*')
        treebase = @tree_base
        search_attributes = ['mail']

        email = nil
        ldap.bind
        ldap.search({
            base: treebase,
            filter: object_filter & login_filter,
            attributes: search_attributes
        }) do |entry|
            email = get_attr(entry, 'mail')
        end

        # Returns email as a promise
        email
    rescue => e
        logger.print_error(e, 'error looking up email')
    end

    def get_attr(entry, attr_name)
        if attr_name != "" && attr_name != nil
            entry[attr_name].is_a?(Array) ? entry[attr_name].first : entry[attr_name]
        end
    end
    # ====================================


    # =======================================
    # EWS Requests to occur in a worker thread
    # =======================================
    def make_ews_booking(start_time, end_time)
        subject = 'On the spot booking'
        user_email = self[:email]

        booking = {
            subject: subject,
            start: start_time,
            end: end_time
        }

        if user_email
            booking[:required_attendees] = [{
                attendee: { mailbox: { email_address: user_email } }
            }]
        end

        cli = Viewpoint::EWSClient.new(*@ews_creds)
        opts = {}

        if @use_act_as
            opts[:act_as] = @ews_room if @ews_room
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
        end

        folder = cli.get_folder(:calendar, opts)
        appointment = folder.create_item(booking)

        # Return the booking IDs
        appointment.item_id
    end

    def delete_ews_booking(delete_at)
        now = Time.now
        if @timezone
            start  = now.in_time_zone(@timezone).midnight
            ending = now.in_time_zone(@timezone).tomorrow.midnight
        else
            start  = now.midnight
            ending = now.tomorrow.midnight
        end

        count = 0

        cli = Viewpoint::EWSClient.new(*@ews_creds)

        if @use_act_as
            # TODO:: think this line can be removed??
            delete_at = Time.parse(delete_at.to_s).to_i

            opts = {}
            opts[:act_as] = @ews_room if @ews_room

            folder = cli.get_folder(:calendar, opts)
            items = folder.items({:calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
            items = cli.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        end

        items.each do |meeting|
            meeting_time = Time.parse(meeting.ews_item[:start][:text])

            # Remove any meetings that match the start time provided
            if meeting_time.to_i == delete_at
                meeting.delete!(:recycle, send_meeting_cancellations: 'SendOnlyToAll')
                count += 1
            end
        end

        # Return the number of meetings removed
        count
    end

    def todays_bookings
        now = Time.now
        if @timezone
            start  = now.in_time_zone(@timezone).midnight
            ending = now.in_time_zone(@timezone).tomorrow.midnight
        else
            start  = now.midnight
            ending = now.tomorrow.midnight
        end

        cli = Viewpoint::EWSClient.new(*@ews_creds)

        if @use_act_as
            opts = {}
            opts[:act_as] = @ews_room if @ews_room

            folder = cli.get_folder(:calendar, opts)
            items = folder.items({:calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        else
            cli.set_impersonation(Viewpoint::EWS::ConnectingSID[@ews_connect_type], @ews_room) if @ews_room
            items = cli.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start.utc.iso8601, :end_date => ending.utc.iso8601}})
        end

        skype_exists = set_skype_url = system.exists?(:Skype)
        now_int = now.to_i

        items.select! { |booking| !booking.cancelled? }
        results = items.collect do |meeting|
            item = meeting.ews_item
            start = item[:start][:text]
            ending = item[:end][:text]

            # Extract the skype meeting URL
            if set_skype_url
                real_start = Time.parse(start)
                start_integer = real_start.to_i - @skype_start_offset
                real_end = Time.parse(ending)
                end_integer = real_end.to_i - @skype_end_offset

                if now_int > start_integer && now_int < end_integer
                    meeting.get_all_properties!

                    if meeting.body
                        # Lync: <a name="OutJoinLink">
                        # Skype: <a name="x_OutJoinLink">
                        body_parts = meeting.body.split('OutJoinLink"')
                        if body_parts.length > 1
                            links = body_parts[-1].split('"').select { |link| link.start_with?('https://') }
                            if links[0].present?
                                set_skype_url = false
                                system[:Skype].set_uri(links[0])
                            end
                        end
                    end
                end

                if @timezone
                    start = real_start.in_time_zone(@timezone).iso8601[0..18]
                    ending = real_end.in_time_zone(@timezone).iso8601[0..18]
                end
            elsif @timezone
                start = Time.parse(start).in_time_zone(@timezone).iso8601[0..18]
                ending = Time.parse(ending).in_time_zone(@timezone).iso8601[0..18]
            end

            {
                :Start => start,
                :End => ending,
                :Subject => item[:subject][:text],
                :owner => item[:organizer][:elems][0][:mailbox][:elems][0][:name][:text]
            }
        end

        system[:Skype].set_uri(nil) if skype_exists && set_skype_url

        results
    end
    # =======================================
end

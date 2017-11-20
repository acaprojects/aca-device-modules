# frozen_string_literal: true

module Aca; end
module Aca::Tracking; end

# Tracks currently connected device
# Tracks reservation and performs basic reservation management

class Aca::Tracking::SwitchPort < CouchbaseOrm::Base
    design_document :swport

    # Connection details
    attribute :mac_address, type: String  # MAC of the device currently connected to the switch
    attribute :device_ip,   type: String  # IP of the device connected to the switch

    # Reservation details
    attribute :unplug_time,  type: Integer, default: 0 # Unlug time for timeout
    attribute :reserve_time, type: Integer, default: 0 # Length of time for the reservation
    attribute :reserved_mac, type: String
    attribute :reserved_by,  type: String
    attribute :desk_id,      type: String

    # Switch details
    attribute :switch_ip,   type: String  # IP of the network switch
    attribute :hostname,    type: String  # defined on switch
    attribute :switch_name, type: String  # defined in backoffice
    attribute :interface,   type: String  # the switch port this device is connected

    validates :switch_ip,   presence: true
    validates :interface,   presence: true

    # self.find_by_switch_ip(ip) => Enumerator
    index_view :switch_ip

    # self.find_by_mac_address(mac) => nil or SwitchPort
    index :mac_address,  presence: false
    index :reserved_mac, presence: false
    index :desk_id,      presence: false

    def self.locate(mac)
        port = ::Aca::Tracking::SwitchPort.find_by_mac_address(mac)
        return port if port

        port = ::Aca::Tracking::SwitchPort.find_by_reserved_mac(mac)
        return port if port && (port.unplug_time + port.reserve_time) >= Time.now.to_i

        nil
    end

    # ================
    # EVENT PROCESSING
    # ================

    # A new device has connected to the switch port
    def connected(mac_address, reserve_time, **switch_details)
        reserved = reserved? && mac_address != self.reserved_mac
        if reserved
            # Check if the owner of this desk has moved somewhere else
            other = self.class.find_by_mac_address(self.reserved_mac)
            reserved = false if other&.id != self.id
        end

        if not reserved
            self.unplug_time = 0
            username = self.class.bucket.get("macuser-#{self.mac_address}", quiet: true)

            if username
                reserved = true
                self.reserve_time = reserve_time
                self.reserved_mac = mac_address
                self.reserved_by = username
            else
                self.reserve_time = 0
                self.reserved_mac = nil
                self.reserved_by = nil
            end
        end
        self.mac_address = mac_address
        self.assign_attributes(switch_details)
        self.save!(with_cas: true)

        reserved
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    # Change the owner of the desk to this new user
    def check_for_user(reserve_time)
        return false if !connected?
        if reserved? && self.mac_address != self.reserved_mac
            # Check if the owner of this desk has moved somewhere else
            other = self.class.find_by_mac_address(self.reserved_mac)
            return false if other&.id == self.id
        end

        username = self.class.bucket.get("macuser-#{self.mac_address}", quiet: true)
        return false unless username

        self.reserved_by = username
        self.reserve_time = reserve_time
        self.reserved_mac = self.mac_address
        self.unplug_time = 0
        self.save!(with_cas: true)
        true
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    # Update the reservation (user would like to extend their desk booking)
    def update_reservation(time)
        return false unless self.reserved_mac

        reserved = if connected?
            # If the reserved time has expired then the current connected
            # user is the new owner of the desk
            reserved?
        else
            # Otherwise we can only reserve a desk if the user had been set
            !!self.reserved_mac
        end
        self.update_columns(reserve_time: time.to_i, with_cas: true) if reserved

        # Was the reservation request successful
        reserved
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def disconnected
        return false unless connected?

        # Configure pre-defined reservation on disconnect
        now = Time.now.to_i
        self.unplug_time = now if !reserved?
        self.mac_address = nil
        self.device_ip = nil
        self.save!(with_cas: true)

        # Ask user if they would like to reserve the desk
        self.reserve_time > 0 && now == self.unplug_time
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def reserved?
        (self.unplug_time + self.reserve_time) > Time.now.to_i
    end

    def connected?
        !!self.mac_address
    end

    def clash?
        connected? ? (self.reserved_mac != self.mac_address && reserved?) : false
    end

    class StaticDetails < Hash
        [
            :ip, :mac, :connected, :reserved,
            :clash, :username, :desk_id
        ].each do |key|
            define_method key do
                self[key]
            end

            define_method "#{key}=" do |val|
                self[key] = val
            end
        end
    end

    # pre-calculated lightweight details for this switch port
    def details
        d = StaticDetails.new
        d.ip = self.device_ip
        d.mac = self.mac_address || self.reserved_mac
        d.connected = connected?
        d.clash = clash?

        # Reserved if there is a clash
        # Reserved if connected and macs are the same
        # Otherwise check if reserved in the traditonal sense
        d.reserved = d.clash ? true : (d.connected ? self.reserved_mac == self.mac_address : reserved?)
        d.username = self.reserved_by if d.reserved
        d.desk_id  = self.desk_id
        d
    end


    protected


    before_create :set_id
    def set_id
        self.id = "swport-#{self.switch_ip}-#{interface}"
    end
end

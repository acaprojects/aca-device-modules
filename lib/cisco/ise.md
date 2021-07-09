
# Cisco ISE Service

Based on documentation from

* https://github.com/marksull/cisco-ise/blob/master/lib/cisco-ise/http-session.rb
* https://www.cisco.com/c/en/us/td/docs/security/ise/1-4/api_ref_guide/api_ref_book/ise_api_ref_ch1.html
* https://www.cisco.com/c/en/us/td/docs/security/ise/1-4/api_ref_guide/api_ref_book/ise_api_ref_ch2.html


## Getting User Session Data

API path:

* /admin/API/mnt/Session/UserName/username
* Uses basic authentication


```xml

<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<xs:schema version="1.0" xmlns:xs="http://www.w3.org/2001/XMLSchema">
    <xs:element name="sessionParameters" type="restsdStatus"/>
    <xs:complexType name="restsdStatus">
        <xs:sequence>
            <xs:element name="passed" type="xs:anyType" minOccurs="0"/>
            <xs:element name="failed" type="xs:anyType" minOccurs="0"/>
            <xs:element name="user_name" type="xs:string" minOccurs="0"/>
            <xs:element name="nas_ip_address" type="xs:string" minOccurs="0"/>
            <xs:element name="failure_reason" type="xs:string" minOccurs="0"/>
            <xs:element name="calling_station_id" type="xs:string" minOccurs="0"/>
            <xs:element name="nas_port" type="xs:string" minOccurs="0"/>
            <xs:element name="identity_group" type="xs:string" minOccurs="0"/>
            <xs:element name="network_device_name" type="xs:string" minOccurs="0"/>
            <xs:element name="acs_server" type="xs:string" minOccurs="0"/>
            <xs:element name="authen_protocol" type="xs:string" minOccurs="0"/>
            <xs:element name="framed_ip_address" type="xs:string" minOccurs="0"/>
            <xs:element name="network_device_groups" type="xs:string" minOccurs="0"/>
            <xs:element name="access_service" type="xs:string" minOccurs="0"/>
            <xs:element name="auth_acs_timestamp" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="authentication_method" type="xs:string" minOccurs="0"/>
            <xs:element name="execution_steps" type="xs:string" minOccurs="0"/>
            <xs:element name="radius_response" type="xs:string" minOccurs="0"/>
            <xs:element name="audit_session_id" type="xs:string" minOccurs="0"/>
            <xs:element name="nas_identifier" type="xs:string" minOccurs="0"/>
            <xs:element name="nas_port_id" type="xs:string" minOccurs="0"/>
            <xs:element name="nac_policy_compliance" type="xs:string" minOccurs="0"/>
            <xs:element name="auth_id" type="xs:long" minOccurs="0"/>
            <xs:element name="auth_acsview_timestamp" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="message_code" type="xs:string" minOccurs="0"/>
            <xs:element name="acs_session_id" type="xs:string" minOccurs="0"/>
            <xs:element name="service_selection_policy" type="xs:string" minOccurs="0"/>
            <xs:element name="authorization_policy" type="xs:string" minOccurs="0"/>
            <xs:element name="identity_store" type="xs:string" minOccurs="0"/>
            <xs:element name="response" type="xs:string" minOccurs="0"/>
            <xs:element name="service_type" type="xs:string" minOccurs="0"/>
            <xs:element name="cts_security_group" type="xs:string" minOccurs="0"/>
            <xs:element name="use_case" type="xs:string" minOccurs="0"/>
            <xs:element name="cisco_av_pair" type="xs:string" minOccurs="0"/>
            <xs:element name="ad_domain" type="xs:string" minOccurs="0"/>
            <xs:element name="acs_username" type="xs:string" minOccurs="0"/>
            <xs:element name="radius_username" type="xs:string" minOccurs="0"/>
            <xs:element name="nac_role" type="xs:string" minOccurs="0"/>
            <xs:element name="nac_username" type="xs:string" minOccurs="0"/>
            <xs:element name="nac_posture_token" type="xs:string" minOccurs="0"/>
            <xs:element name="nac_radius_is_user_auth" type="xs:string" minOccurs="0"/>
            <xs:element name="selected_posture_server" type="xs:string" minOccurs="0"/>
            <xs:element name="selected_identity_store" type="xs:string" minOccurs="0"/>
            <xs:element name="authentication_identity_store" type="xs:string" minOccurs="0"/>
            <xs:element name="azn_exp_pol_matched_rule" type="xs:string" minOccurs="0"/>
            <xs:element name="ext_pol_server_matched_rule" type="xs:string" minOccurs="0"/>
            <xs:element name="grp_mapping_pol_matched_rule" type="xs:string" minOccurs="0"/>
            <xs:element name="identity_policy_matched_rule" type="xs:string" minOccurs="0"/>
            <xs:element name="nas_port_type" type="xs:string" minOccurs="0"/>
            <xs:element name="query_identity_stores" type="xs:string" minOccurs="0"/>
            <xs:element name="selected_azn_profiles" type="xs:string" minOccurs="0"/>
            <xs:element name="sel_exp_azn_profiles" type="xs:string" minOccurs="0"/>
            <xs:element name="selected_query_identity_stores" type="xs:string" minOccurs="0"/>
            <xs:element name="eap_tunnel" type="xs:string" minOccurs="0"/>
            <xs:element name="tunnel_details" type="xs:string" minOccurs="0"/>
            <xs:element name="cisco_h323_attributes" type="xs:string" minOccurs="0"/>
            <xs:element name="cisco_ssg_attributes" type="xs:string" minOccurs="0"/>
            <xs:element name="other_attributes" type="xs:string" minOccurs="0"/>
            <xs:element name="response_time" type="xs:long" minOccurs="0"/>
            <xs:element name="nad_failure" type="xs:anyType" minOccurs="0"/>
            <xs:element name="destination_ip_address" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_id" type="xs:long" minOccurs="0"/>
            <xs:element name="acct_acs_timestamp" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="acct_acsview_timestamp" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="acct_session_id" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_status_type" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_session_time" type="xs:long" minOccurs="0"/>
            <xs:element name="acct_input_octets" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_output_octets" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_input_packets" type="xs:long" minOccurs="0"/>
            <xs:element name="acct_output_packets" type="xs:long" minOccurs="0"/>
            <xs:element name="acct_class" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_terminate_cause" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_multi_session_id" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_authentic" type="xs:string" minOccurs="0"/>
            <xs:element name="termination_action" type="xs:string" minOccurs="0"/>
            <xs:element name="session_timeout" type="xs:string" minOccurs="0"/>
            <xs:element name="idle_timeout" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_interim_interval" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_delay_time" type="xs:string" minOccurs="0"/>
            <xs:element name="event_timestamp" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_tunnel_connection" type="xs:string" minOccurs="0"/>
            <xs:element name="acct_tunnel_packet_lost" type="xs:string" minOccurs="0"/>
            <xs:element name="security_group" type="xs:string" minOccurs="0"/>
            <xs:element name="cisco_h323_setup_time" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="cisco_h323_connect_time" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="cisco_h323_disconnect_time" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="framed_protocol" type="xs:string" minOccurs="0"/>
            <xs:element name="started" type="xs:anyType" minOccurs="0"/>
            <xs:element name="stopped" type="xs:anyType" minOccurs="0"/>
            <xs:element name="ckpt_id" type="xs:long" minOccurs="0"/>
            <xs:element name="type" type="xs:long" minOccurs="0"/>
            <xs:element name="nad_acsview_timestamp" type="xs:dateTime" minOccurs="0"/>
            <xs:element name="vlan" type="xs:string" minOccurs="0"/>
            <xs:element name="dacl" type="xs:string" minOccurs="0"/>
            <xs:element name="authentication_type" type="xs:string" minOccurs="0"/>
            <xs:element name="interface_name" type="xs:string" minOccurs="0"/>
            <xs:element name="reason" type="xs:string" minOccurs="0"/>
            <xs:element name="endpoint_policy" type="xs:string" minOccurs="0"/>
        </xs:sequence>
    </xs:complexType>
</xs:schema>

```


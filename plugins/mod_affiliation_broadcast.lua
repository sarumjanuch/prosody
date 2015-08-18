local st = require "util.stanza";
log("debug", "Module Affiliation broadcast");
module:hook("muc-set-affiliation", function(event)
	local room = event.room;
	local body = string.format("Member %s affiliation in room %s is now %s.", event.jid, room.jid, event.affiliation);
	log("debug", "Member %s affiliation in room %s is now %s.", event.jid, room.jid, event.affiliation);
	local code, type, stanza;
	if event.affiliation == "none" then
		code = "400"
		type = "unavailable"
	else 
		code = "250"
		
	end	
	for jid in room:each_affiliation("member") do
			if code == "400" then
				stanza = st.presence { 
				type = type;
				from = room.jid;
				to = jid;
				}
			else
	                        stanza = st.presence {
                                from = room.jid;
                                to = jid;
                        	}
			end 

			local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("item", {affiliation=event.affiliation; jid=event.jid; room=room.jid}):up()
				:tag("status",{code=code})
			stanza:add_child(x);
		log("debug","Affiliation presence stanza: %s", tostring(stanza))
		room:route_stanza(stanza);
	end
end);

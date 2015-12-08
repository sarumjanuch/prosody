local jid_bare = require "util.jid".bare;
local http = require "socket.http";
local json_encode = require "util.json";

local send_message_as_push;

module:hook("muc-broadcast-message", function (event)
	module:log("info", "Received Group message");
  local room, stanza = event.room, event.stanza;
	local name, subject = room:get_subject();
	local text = stanza:get_child_text("body");
  if text then
	  for jid in room:each_affiliation("member") do
      if not room:get_occupant_jid(jid .. "/Work-PC") then
				send_message_as_push(jid, jid_bare(stanza.attr.from), stanza.attr.id, stanza.attr.type, text, subject);	
			end
		end

    for jid in room:each_affiliation("owner") do
    	if not room:get_occupant_jid(jid .. "/Work-PC") then
		    send_message_as_push(jid, jid_bare(stanza.attr.from), stanza.attr.id, stanza.attr.type, text, subject)
			end
  	end
	end
end);

module:hook("message/offline/handle", function(event)
	local stanza = event.stanza;
	local text = stanza:get_child_text("body");
	if text then
		return send_message_as_push(jid_bare(stanza.attr.to), jid_bare(stanza.attr.from), stanza.attr.id, stanza.attr.type, text, "");
	end
end, 1);

function send_message_as_push(to, from, id, type, body, subject)
	module:log("info", "Pushing offline message via GCM to: %s", to);
	module:log("info", "From: %s, To: %s, Message: %s, Id: %s, Type: %s, Subject: %s", from, to, body, id, type, subject);
	
	local post_url = "http://localhost:5000/publish/post/xmpp?from=".. urlencode(from) .. "&to=" .. urlencode(to) .. "&body=" .. urlencode(body) .. "&mid=" .. urlencode(id) .. "&type=" .. urlencode(type) .. "&subject=" .. urlencode(subject); 

	local ok, err = http.request(post_url);

	if not ok then
		module:log("error", "Failed to deliver to %s: %s", tostring(address), tostring(err));
		return;
	end
	return true;
end

function urlencode(str)
if (str) then
  str = string.gsub (str, "\n", "\r\n")
  str = string.gsub (str, "([^%w ])",
  function (c) return string.format ("%%%02X", string.byte(c)) end)
  str = string.gsub (str, " ", "+")
end
return str
end

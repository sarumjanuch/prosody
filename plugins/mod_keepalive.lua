local interval = module:get_option_number('keepalive_interval', 60);
local timer = require "util.timer";

module:log("debug", "Keepalive module loaded, interval is %s", interval);

module:hook("resource-bind", function(event)
        local session, err = event.session, event.error;
        if session.timer == nil then
		module:log("debug", "Keepalive enabled for session %s", session.full_jid);
		-- Send first message after short delay, this will give client a time to enable keepalive
		timer.add_task(5, function()
                        session.send("h");
                end)
		-- Here we start interval that will run untill we kill timer
                session.timer = timer.add_task(interval, function()
			session.send("h"); 
			return interval; 
		end)
        end
end);

module:hook("pre-resource-unbind", function(event)
        local session, err = event.session, event.error;
	if session.timer ~= nil then
		timer.stop(session.timer);
		module:log("debug", "Keepalive disabled for session %s", session.full_jid)
	end
end);


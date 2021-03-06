
local setmetatable, getmetatable = setmetatable, getmetatable;
local ipairs, unpack, select = ipairs, unpack, select;
local tonumber, tostring = tonumber, tostring;
local assert, xpcall, debug_traceback = assert, xpcall, debug.traceback;
local t_concat = table.concat;
local s_char = string.char;
local log = require "util.logger".init("sql");

local DBI = require "DBI";
-- This loads all available drivers while globals are unlocked
-- LuaDBI should be fixed to not set globals.
DBI.Drivers();
local build_url = require "socket.url".build;

module("sql")

local column_mt = {};
local table_mt = {};
local query_mt = {};
--local op_mt = {};
local index_mt = {};

function is_column(x) return getmetatable(x)==column_mt; end
function is_index(x) return getmetatable(x)==index_mt; end
function is_table(x) return getmetatable(x)==table_mt; end
function is_query(x) return getmetatable(x)==query_mt; end
function Integer(n) return "Integer()" end
function String(n) return "String()" end

function Column(definition)
	return setmetatable(definition, column_mt);
end
function Table(definition)
	local c = {}
	for i,col in ipairs(definition) do
		if is_column(col) then
			c[i], c[col.name] = col, col;
		elseif is_index(col) then
			col.table = definition.name;
		end
	end
	return setmetatable({ __table__ = definition, c = c, name = definition.name }, table_mt);
end
function Index(definition)
	return setmetatable(definition, index_mt);
end

function table_mt:__tostring()
	local s = { 'name="'..self.__table__.name..'"' }
	for i,col in ipairs(self.__table__) do
		s[#s+1] = tostring(col);
	end
	return 'Table{ '..t_concat(s, ", ")..' }'
end
table_mt.__index = {};
function table_mt.__index:create(engine)
	return engine:_create_table(self);
end
function table_mt:__call(...)
	-- TODO
end
function column_mt:__tostring()
	return 'Column{ name="'..self.name..'", type="'..self.type..'" }'
end
function index_mt:__tostring()
	local s = 'Index{ name="'..self.name..'"';
	for i=1,#self do s = s..', "'..self[i]:gsub("[\\\"]", "\\%1")..'"'; end
	return s..' }';
--	return 'Index{ name="'..self.name..'", type="'..self.type..'" }'
end

local function urldecode(s) return s and (s:gsub("%%(%x%x)", function (c) return s_char(tonumber(c,16)); end)); end
local function parse_url(url)
	local scheme, secondpart, database = url:match("^([%w%+]+)://([^/]*)/?(.*)");
	assert(scheme, "Invalid URL format");
	local username, password, host, port;
	local authpart, hostpart = secondpart:match("([^@]+)@([^@+])");
	if not authpart then hostpart = secondpart; end
	if authpart then
		username, password = authpart:match("([^:]*):(.*)");
		username = username or authpart;
		password = password and urldecode(password);
	end
	if hostpart then
		host, port = hostpart:match("([^:]*):(.*)");
		host = host or hostpart;
		port = port and assert(tonumber(port), "Invalid URL format");
	end
	return {
		scheme = scheme:lower();
		username = username; password = password;
		host = host; port = port;
		database = #database > 0 and database or nil;
	};
end

local engine = {};
function engine:connect()
	if self.conn then return true; end

	local params = self.params;
	assert(params.driver, "no driver")
	log("debug", "Connecting to [%s] %s...", params.driver, params.database);
	local dbh, err = DBI.Connect(
		params.driver, params.database,
		params.username, params.password,
		params.host, params.port
	);
	if not dbh then return nil, err; end
	dbh:autocommit(false); -- don't commit automatically
	self.conn = dbh;
	self.prepared = {};
	local ok, err = self:set_encoding();
	if not ok then
		return ok, err;
	end
	local ok, err = self:onconnect();
	if ok == false then
		return ok, err;
	end
	return true;
end
function engine:onconnect()
	-- Override from create_engine()
end
function engine:execute(sql, ...)
	local success, err = self:connect();
	if not success then return success, err; end
	local prepared = self.prepared;

	local stmt = prepared[sql];
	if not stmt then
		local err;
		stmt, err = self.conn:prepare(sql);
		if not stmt then return stmt, err; end
		prepared[sql] = stmt;
	end

	local success, err = stmt:execute(...);
	if not success then return success, err; end
	return stmt;
end

local result_mt = { __index = {
	affected = function(self) return self.__stmt:affected(); end;
	rowcount = function(self) return self.__stmt:rowcount(); end;
} };

function engine:execute_query(sql, ...)
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	local stmt = assert(self.conn:prepare(sql));
	assert(stmt:execute(...));
	return stmt:rows();
end
function engine:execute_update(sql, ...)
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	local prepared = self.prepared;
	local stmt = prepared[sql];
	if not stmt then
		stmt = assert(self.conn:prepare(sql));
		prepared[sql] = stmt;
	end
	assert(stmt:execute(...));
	return setmetatable({ __stmt = stmt }, result_mt);
end
engine.insert = engine.execute_update;
engine.select = engine.execute_query;
engine.delete = engine.execute_update;
engine.update = engine.execute_update;
function engine:_transaction(func, ...)
	if not self.conn then
		local ok, err = self:connect();
		if not ok then return ok, err; end
	end
	--assert(not self.__transaction, "Recursive transactions not allowed");
	local args, n_args = {...}, select("#", ...);
	local function f() return func(unpack(args, 1, n_args)); end
	self.__transaction = true;
	local success, a, b, c = xpcall(f, debug_traceback);
	self.__transaction = nil;
	if success then
		log("debug", "SQL transaction success [%s]", tostring(func));
		local ok, err = self.conn:commit();
		if not ok then return ok, err; end -- commit failed
		return success, a, b, c;
	else
		log("debug", "SQL transaction failure [%s]: %s", tostring(func), a);
		if self.conn then self.conn:rollback(); end
		return success, a;
	end
end
function engine:transaction(...)
	local ok, ret = self:_transaction(...);
	if not ok then
		local conn = self.conn;
		if not conn or not conn:ping() then
			self.conn = nil;
			ok, ret = self:_transaction(...);
		end
	end
	return ok, ret;
end
function engine:_create_index(index)
	local sql = "CREATE INDEX `"..index.name.."` ON `"..index.table.."` (";
	for i=1,#index do
		sql = sql.."`"..index[i].."`";
		if i ~= #index then sql = sql..", "; end
	end
	sql = sql..");"
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	elseif self.params.driver == "MySQL" then
		sql = sql:gsub("`([,)])", "`(20)%1");
	end
	if index.unique then
		sql = sql:gsub("^CREATE", "CREATE UNIQUE");
	end
	--print(sql);
	return self:execute(sql);
end
function engine:_create_table(table)
	local sql = "CREATE TABLE `"..table.name.."` (";
	for i,col in ipairs(table.c) do
		local col_type = col.type;
		if col_type == "MEDIUMTEXT" and self.params.driver ~= "MySQL" then
			col_type = "TEXT"; -- MEDIUMTEXT is MySQL-specific
		end
		if col.auto_increment == true and self.params.driver == "PostgreSQL" then
			col_type = "BIGSERIAL";
		end
		sql = sql.."`"..col.name.."` "..col_type;
		if col.nullable == false then sql = sql.." NOT NULL"; end
		if col.primary_key == true then sql = sql.." PRIMARY KEY"; end
		if col.auto_increment == true then
			if self.params.driver == "MySQL" then
				sql = sql.." AUTO_INCREMENT";
			elseif self.params.driver == "SQLite3" then
				sql = sql.." AUTOINCREMENT";
			end
		end
		if i ~= #table.c then sql = sql..", "; end
	end
	sql = sql.. ");"
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	elseif self.params.driver == "MySQL" then
		sql = sql:gsub(";$", (" CHARACTER SET '%s' COLLATE '%s_bin';"):format(self.charset, self.charset));
	end
	local success,err = self:execute(sql);
	if not success then return success,err; end
	for i,v in ipairs(table.__table__) do
		if is_index(v) then
			self:_create_index(v);
		end
	end
	return success;
end
function engine:set_encoding() -- to UTF-8
	local driver = self.params.driver;
	if driver == "SQLite3" then
		return self:transaction(function()
			if self:select"PRAGMA encoding;"()[1] == "UTF-8" then
				self.charset = "utf8";
			end
		end);
	end
	local set_names_query = "SET NAMES '%s';"
	local charset = "utf8";
	if driver == "MySQL" then
		local ok, charsets = self:transaction(function()
			return self:select"SELECT `CHARACTER_SET_NAME` FROM `information_schema`.`CHARACTER_SETS` WHERE `CHARACTER_SET_NAME` LIKE 'utf8%' ORDER BY MAXLEN DESC LIMIT 1;";
		end);
		local row = ok and charsets();
		charset = row and row[1] or charset;
		set_names_query = set_names_query:gsub(";$", (" COLLATE '%s';"):format(charset.."_bin"));
	end
	self.charset = charset;
	log("debug", "Using encoding '%s' for database connection", charset);
	local ok, err = self:transaction(function() return self:execute(set_names_query:format(charset)); end);
	if not ok then
		return ok, err;
	end
	
	if driver == "MySQL" then
		local ok, actual_charset = self:transaction(function ()
			return self:select"SHOW SESSION VARIABLES LIKE 'character_set_client'";
		end);
		for row in actual_charset do
			if row[2] ~= charset then
				log("error", "MySQL %s is actually %q (expected %q)", row[1], row[2], charset);
				return false, "Failed to set connection encoding";
			end
		end
	end
	
	return true;
end
local engine_mt = { __index = engine };

function db2uri(params)
	return build_url{
		scheme = params.driver,
		user = params.username,
		password = params.password,
		host = params.host,
		port = params.port,
		path = params.database,
	};
end

function create_engine(self, params, onconnect)
	return setmetatable({ url = db2uri(params), params = params, onconnect = onconnect }, engine_mt);
end

return _M;

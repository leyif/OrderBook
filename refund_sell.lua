--[[
    ARGV[1]: 操作号
    ARGV[2]: 订单号
]]

local opt_no = tonumber(ARGV[1])
-- local opt_no = redis.call('INCR', 'OPT-NO')
if redis.call('GETBIT', 'OPT-NO-BIT', opt_no) == 1 then
    return redis.call('GET', 'OPT-'..opt_no)
end

redis.call('SETBIT', 'OPT-NO-BIT', opt_no, 1)

local order_no = ARGV[2]
local count = redis.call('ZREM', 'ORDER-BOOK-SELL', order_no)
local sell_num = redis.call('GET', 'ORDER-'..order_no)
redis.call('DEL', 'ORDER-'..order_no)
redis.call('SET', 'OPT-'..opt_no, sell_num)

return sell_num
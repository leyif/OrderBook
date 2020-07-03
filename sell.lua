--[[
    ARGV[1]: 操作号
    ARGV[2]: 订单价格
    ARGV[3]: 订单股数量
]]

local opt_no = tonumber(ARGV[1])
-- local opt_no = redis.call('INCR', 'OPT-NO')
if redis.call('GETBIT', 'OPT-NO-BIT', opt_no) == 1 then
    return redis.call('GET', 'OPT-'..opt_no)
end

redis.call('SETBIT', 'OPT-NO-BIT', opt_no, 1)

local order_no = redis.call('INCR', 'ORDER-NO')
local sell_num = tonumber(ARGV[3]) -- 记录剩余股数量
local sell_price = tonumber(ARGV[2])
local temp_order_no = '' -- 记录内部临时订单key, 减少重复local和拼接
local kvs = {} -- 记录价格最低的买单, 减少重复local
local buy_num = 0 -- 记录价格最低的卖单, 减少重复local
while true
do
    -- 从高到低
    kvs = redis.call('ZREVRANGE', 'ORDER-BOOK-BUY', 0, 0, 'WITHSCORES')

    -- 没有卖单
    if not kvs[1] then
        break
    end

    -- 卖价高于买价
    if tonumber(kvs[2]) < sell_price then
        break
    end

    temp_order_no = 'ORDER-'..kvs[1]
    buy_num = tonumber(redis.call('GET', temp_order_no))
    if sell_num >= buy_num then
        -- 吃完buy单
        redis.call('DEL', temp_order_no)
        redis.call('ZREM', 'ORDER-BOOK-BUY', kvs[1])
        redis.call('LPUSH', 'BUY-SELL-NUM', order_no..'-'..kvs[1]..'-'..buy_num)
        sell_num = sell_num - buy_num
    else
        -- 吃完sell单
        redis.call('INCRBY', temp_order_no, -sell_num)
        redis.call('LPUSH', 'BUY-SELL-NUM', order_no..'-'..kvs[1]..'-'..sell_num)
        sell_num = 0
    end

    if sell_num == 0 then
        break
    end
end

-- 交易匹配完仍有剩余
if sell_num > 0 then
    redis.call('ZADD', 'ORDER-BOOK-SELL', sell_price, order_no)
    redis.call('SET', 'ORDER-'..order_no, sell_num)
end
redis.call('SET', 'OPT-'..opt_no, order_no)
return order_no

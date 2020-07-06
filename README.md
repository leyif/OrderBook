# OrderBook

撮合交易在 Redis 的一种实现



## 撮合逻辑

整体业务流程里，核心资源是两个属性：余额、标准商品。那么，以此为基础产生的两个基础操作为：

- 以单价为X的价格，出售数量为Y标准商品。
- 以单价为X的价格，购买数量为Y标准商品。

当用户进行这两个操作的时候，会以事务的方式进行余额、标准商品的冻结和相应订单的产生。

当订单产生后，会有两种结果：

- 订单未达成匹配，则呆在某个地方等待匹配
- 订单达成匹配，数量少的订单被完全匹配，数量多的订单则仍有剩余，继续等待下次匹配

那匹配规则是什么：

1. 价格。出价越低，越容易出售。出价越高，越容易购买。所以，购买订单是以价格从高到低进行排列的，而出售订单是以价格从低到高进行排序的。
2. 时间。在价格的基础上，若遇到了相同的出价，则越早下单的人越优先被匹配。



## 为什么是Redis

首先，在我们尽可能保留少的层次、仅有服务层和数据层的时候，看看会遇到什么问题。

**顺序问题**：

存在顺序产生的3个订单A、B、C，后续进入的B和C订单都能跟A订单产生匹配，理论上先进入的B订单应该优先跟A订单匹配，匹配完成之后再由C订单继续匹配，但实际上B、C订单的创建时间非常接近，由于服务层和数据层间的时延，C订单可能先于B订单对A进行了匹配。这点类似于排序算法中的稳定性。

**解决方案**：

- 引入队列，并且将消费者数量设置为1，达到串行化的目的。缺点，撮合性能取决于队列消费能力，而消费者数量只有1的话，性能会下降。
- （存疑）数据层的存储过程。
- 以匹配时间作为订单顺序依据。出现顺序问题时，多个订单的时间间隔一定是非常小的，那么可将匹配的顺序作为订单的时间排序顺序，在业务上也是能够接受的。

**性能问题**：

1. 数据写：订单的创建、匹配成功后的结算订单生成和匹配订单修改。在InnoDB默认配置下，每次写操作都会将相关日志文件同步到磁盘。                                                                                  
2. 数据读：对于数据库来说，匹配订单的挑选可以表示为 Where 、 Order 、Limit 的组合查询。Where 进行价格的筛选，Order 是对符合的订单进行价格和时间的排序，Limit 是对符合条件的订单进行数量限制。

**解决方案**：

- 对于数据写，可以修改 sync_binlog 和 innodb_flush_log_at_trx_commit 的配置，减少磁盘写从而提高性能。缺点，牺牲了数据的安全性和一致性。
- 对于数据读，可以对 Order 关联到到相关字段建立联合索引。在建立索引后，每次匹配变成了在B+树上进行查找的操作，由于查找的都是最大或最小的前N项、且N非常接近或直接等于1，那么，目标项的主键必定在第一个索引页中，然后再通过索引页中的主键进行回表找到数据页中的目标项。缺点，虽然索引的查找的效率为O（1），但是回表的效率为O（log（M））。

总结下来，在不引入其他层或中间件的情况下，我们对预期问题的解决方案都有相对应的缺陷。而对于串行化、高性能的场景，Redis 应该再合适不过了。

- 顺序问题：Redis 以事件驱动方式进行串行化处理，将订单的创建和匹配逻辑结合放在Redis中，业务层只做操作的记录。
- 读性能问题：使用Redis中的ZSet（数据结构为SkipList）作为维护订单的方式，每次匹配 实际上都是在队列中寻找头部或者尾部的订单，时间复杂度为O（1）。
- 写性能问题：在Redis中的写数据分为两部分，一是先写内存，二是根据持久化方式的不同去写磁盘。这里主要关注磁盘写的问题。Redis 持久化方式分为RDB和AOF。RDB又分为RDB和BG RDB。AOF根据同步方式的不同又可分为三种，当设置为每条命令都要进行磁盘同步的时候，Redis的性能降级为MySQL级别。

在引入Redis之后，业务又产生了额外的问题：

- 为了保证Redis的性能，部分最新数据存在未持久化进而丢失的风险，要引入其他机制保证这部分的数据。
- 数据一致性。业务层、MySQL跟Redis又需要加入新的设计保证相互之间的最终一致性。

## Redis中的实现

| Redis Key        | Redis Type     | 说明                                                         |
| ---------------- | -------------- | ------------------------------------------------------------ |
| OPT-NO-BIT       | String(bitmap) | 操作号，业务端传递过来的唯一标志，用来做幂等判断             |
| OPT-{OPT-NO}     | String         | 操作号的结果，如果是下单则记录订单号，如果撤单则代表订单剩余数量 |
| BUY-SELL-NUM     | List           | 撮合结果列表，值为{BUY-ORDER-NO}-{SELL-ORDER-NO}-{NUM}       |
| ORDER-BOOK-SELL  | ZSet           | 卖家下单列表，订单簿之一，Key代表订单号，Score代表价格       |
| ORDER-BOOK-BUY   | ZSet           | 买家下单列表，订单簿之一，Key代表订单号，Score代表价格       |
| ORDER-{ORDER_NO} | String         | 订单对应的数量，买卖双方列表共同构成订单簿。                 |
| ORDER-NO         | String         | 简易订单号生成逻辑，每次自增1                                |



### 操作号（OPT-NO）

**操作号的引入主要是解决业务端和Redis的数据一致性，假设没有操作号与操作对应的话，那么在遇到网络波动的情况下，可能会出现一个操作被多次执行或者，一个操作执行成功但没有正确返回。无论哪种情况都会产生业务端和Redis端数据不一致的情况，这是无法接受的。**

引入操作号之后，业务的逻辑变成了：

1. 生成唯一标志作为操作号，将下单的数据（买/卖，价格，数量，下单时间，订单号（默认为空），操作状态（默认为未完成））与生成的操作号绑定存入数据库，与下一步关联为一个事务
2. 检查用户余额是否满足下单操作，满足的话则冻结用户相关余额，与上一步关联为一个事务
3. 将相关参数（买/卖，价格，数量，操作号）发往Redis进行撮合，并返回结果
4. 将结果更新到第1步产生的记录中去，并更新该记录状态
5. 定时扫描第1步中的数据库表，对操作状态异常（未完成）的记录，在Redis查找是否存在操作号相对应的订单号，并根据结果进行订单号和状态更新，或者取消该操作和取消冻结用户余额

在第3步的时候可能因为网络波动产生几种情况：

- 正常发送并成功返回该操作对应的订单号（ORDER-NO）
- 遇到网络问题没有正常返回结果。

遇到第二种情况的时候，可以有两种选择：

- 重试该操作。重试意味着重新将相关参数（买/卖，价格，数量，操作号）发往Redis，而在Redis端的Lua脚本逻辑里，会先判断该操作号是否已经被执行过（通过OPT-NO-BIT），如果执行过则返回相对应的订单号（OPT-{OPT-NO}，如果是撤单则对应订单剩余数量）
- 检查Redis是否存在该操作号对应的订单号。直接查找是否存在相对应的订单号（OPT-{OPT-NO}，如果是撤单则对应订单剩余数量）

至此操作号完成了它应有的使命。



### 订单号（ORDER-NO）

**订单号的引入是为了跟踪每个操作的执行顺序（下单或撤单）。当Redis因不可抗拒力无法恢复到最新的数据（也即有部分最新数据没有持久化），甚至所有数据丢失的时候，可以对丢失的部分或者全部的数据进行重放以恢复最新数据。**

- 当Redis丢失部分数据时，找到Redis当前剩余数据的最大订单号，然后再从数据库中的操作记录（买/卖，价格，数量，下单时间，订单号（默认为空），操作状态（默认为未完成））中，找到比该最大订单号大的记录，然后按照订单号从小到大进入Redis重放操作。
- 将数据库中的全部操作记录（买/卖，价格，数量，下单时间，订单号（默认为空），操作状态（默认为未完成）），按照订单号从小到大进入Redis重放操作。

额外的，订单号的格式是需要值得注意的。在实际业务中，订单簿的排序方式为低价优先，价格相同时则按时间排序，时间这个参数在这个系统可用订单号表示。

在此系统中，订单簿的两个队列使用ZSet类型维护，每个Item的Key为订单号，Score为价格。ZSet排序的时候使用Score进行排序，当两个Score相同的时候，会按照Key进行排序。而在测试过程中，ZSet会把Key当作一个字符串而非数字进行排序，也就意味着一个订单号为2的订单在价格相同时，会排在订单号100的后面。这在业务上肯定是无法接受的。

针对这种情况的话，有两种解决方式：

- 使用一个String类型作为订单的自增字段，并将这个字段给出一个比较高的初值，例如10亿，那么订单号在到下一个进位之前——也就是100亿——之间的排序都是正确的，也就意味着这个系统在保证业务可用的情况下的订单号可用数量为90亿。**这是一种简单的、临时的解决方案，无法在生产环境中使用。**
- 参考Stream的默认ID生成方式，采用本地毫秒时间戳加上64位自增序列号组成，具体可参考[Redis Stream](http://www.redis.cn/topics/streams-intro.html)。这是一种复杂的、可靠的解决方案，可以在生产环境中使用。

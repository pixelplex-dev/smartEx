pragma solidity ^0.4.11;

import './oraclizeAPI.sol';

contract Object {
    address public owner;

    function Object() {
        owner = msg.sender;
    }

    function setOwner(address _owner) onlyOwner() {
        owner = _owner;
    }

    modifier onlyOwner(){
        require(msg.sender == owner);
        _;
    }
}

contract StockExchange is Object, usingOraclize {

    struct Order {
        uint createDate;
        address creator;
        uint248 amount;
        uint248 leverage;
        bool factor;
        uint248 rate;
        bool approved;
        bool closed;
    }

    Order[] public orders;

    uint248 public rate = 0;

    string private url = '';

    mapping(bytes32 => bool) public queriesQueue;
    
    bool updaterIsRunning = false;

    event OrderCreated(
        uint    orderId,
        uint    createDate,
        address creator,
        uint248 amount,
        uint248 leverage,
        bool    factor,
        uint248 openRate
    );
    event OrderApproved(
        uint    orderId,
        uint    createDate,
        address creator,
        uint248 amount,
        uint248 leverage,
        bool    factor,
        uint248 openRate
    );
    event OrderClosed(
        uint    orderId,
        uint    createDate,
        address creator,
        uint248 creationAmount,
        uint248 closingAmount,
        uint248 leverage,
        bool    factor,
        uint248 creationRate,
        uint248 closingRate,
        string  initiator
    );
    event RateUpdated(string newRate, bytes32 queryId);
    event UpdaterStatusUpdated(string status);

    function() payable {
        if(!updaterIsRunning && bytes(url).length != 0){
            updaterIsRunning = true;
            UpdaterStatusUpdated('running');
            _requestRate();
        }
    }

    function destroy() onlyOwner() {
        for(uint i = 0; i < orders.length; i++){
            if(!orders[i].closed){
                if(orders[i].approved){
                    int256 resultAmount = _calculateAmount(orders[i]);
                    _processOrderCompletion(i, resultAmount, 'contract');
                } else {
                    _processOrderCompletion(i, orders[i].amount, 'contract');
                }
            }
        }
        selfdestruct(msg.sender);    
    }

    function setUrl(string _url) internal {
        url = _url;
    }

    //factor: true for buying | false for selling
    function openOrder(uint248 leverage, bool factor) payable {
        require(rate != 0);
        require(msg.value > 0);
        require(leverage >= 1 && leverage <= 100);

        uint orderId = orders.length;
        orders.push(Order({
            createDate : now,
            creator : msg.sender,
            amount  : uint248(msg.value),
            leverage: leverage,
            factor  : factor,
            rate    : rate,
            approved: false,
            closed  : false
        }));
        OrderCreated(
            orderId,
            now,
            msg.sender,
            uint248(msg.value),
            leverage,
            factor,
            rate
        );
    }

    function approveOrder(uint orderId) onlyOwner() payable {
        require(orders[orderId].amount != 0);
        require(!orders[orderId].closed);
        require(!orders[orderId].approved); 
        require(uint248(msg.value) >= orders[orderId].amount); 

        orders[orderId].approved = true;
        OrderApproved(
            orderId, 
            orders[orderId].createDate,
            orders[orderId].creator,
            orders[orderId].amount,
            orders[orderId].leverage,
            orders[orderId].factor,
            orders[orderId].rate
        );
    }

    function closeOrder(uint orderId) {
        require(msg.sender == owner || msg.sender == orders[orderId].creator);
        require(!orders[orderId].closed);
        int256 resultAmount = orders[orderId].approved ? _calculateAmount(orders[orderId]) : int256(orders[orderId].amount);
        _processOrderCompletion(orderId, resultAmount, msg.sender == orders[orderId].creator ? 'trader' : 'admin');
    }

    //oraclize.it callback
    function __callback(bytes32 queryId, string result) {
        require(msg.sender == oraclize_cbAddress());
        if(queriesQueue[queryId]) return;
        queriesQueue[queryId] = true;

        rate = uint248(parseInt(result, 9));
        RateUpdated(result, queryId);

        _processOrderCheck();
        _requestRate();
    }

    function _requestRate() internal {
        if(oraclize_getPrice("URL") < this.balance){
            bytes32 queryId = oraclize_query(60, "URL", url);
            queriesQueue[queryId] = false;
        } else {
            updaterIsRunning = false;
            UpdaterStatusUpdated('stopped');
        }
    }

    function _processOrderCheck() internal {
        for(uint i = 0; i < orders.length; i++){
            if(!orders[i].closed){
                if(orders[i].approved){
                    int256 resultAmount = _calculateAmount(orders[i]);
                    if(resultAmount >= int256(orders[i].amount * 180 / 100) || resultAmount <= int256(orders[i].amount * 20 / 100)){
                        _processOrderCompletion(i, resultAmount, 'contract');
                    }
                } else {
                    if(now >= orders[i].createDate + 10 minutes){
                        _processOrderCompletion(i, orders[i].amount, 'contract');
                    }
                }
            }
        }
    }

    function _processOrderCompletion(uint orderId, int256 resultAmount, string initiator) internal {
        uint sendingAmount = uint(resultAmount); 
        uint maxAmount = uint(orders[orderId].amount * 180 / 100);
        uint minAmount = uint(orders[orderId].amount * 20 / 100);

        if(sendingAmount > maxAmount) {
            sendingAmount = maxAmount;
        } else if(sendingAmount < minAmount) {
            sendingAmount = minAmount;
        } 
        orders[orderId].creator.transfer(sendingAmount);
        orders[orderId].closed = true;
        OrderClosed(
            orderId,
            orders[orderId].createDate,
            orders[orderId].creator,
            uint248(orders[orderId].amount),
            uint248(sendingAmount),
            orders[orderId].leverage,
            orders[orderId].factor,
            orders[orderId].rate,
            rate,
            initiator
        );
    }

    function _calculateAmount(Order order) internal returns(int256) {
        int256 delta = int256(order.leverage) *  int256(rate - order.rate) * int256(order.amount) / int256(order.rate) ;
        return order.factor ? (order.amount + delta) : (order.amount - delta);
    }
}

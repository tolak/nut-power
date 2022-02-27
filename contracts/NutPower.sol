//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract NutPower is Ownable {
    using SafeMath for uint256;

    uint256 constant WEEK = 604800;
    uint256 constant PERIOD_COUNT = 7;

    enum Period {
        W1,
        W2,
        W4,
        W8,
        W16,
        W32,
        W64
    }

    struct DepositInfo {
        // Locked NUT amount
        uint256 amount;
        uint256 lastUpdateTime;
    }

    struct RedeemRequest {
        uint256 amount;
        uint256 claimed;
        uint256 startTime;
        uint256 endTime;
    }

    struct RequestsOfPeriod {
        uint256 index;
        RedeemRequest[] queue;
    }

    struct PowerInfo {
        // Amount of NP can be power down
        uint256 free;
        // Amount of NP has been locked, e.g. staked
        uint256 locked;
    }

    address private nut;
    address private guage;

    uint256 private totalSupple;
    mapping (address => uint256) private _allowances;

    mapping (address => PowerInfo) powers;
    mapping (address => mapping (Period => DepositInfo)) depositInfos;
    uint256[] multipier = [1, 2, 4, 8, 16, 32, 64];
    mapping (address => mapping (Period => RequestsOfPeriod)) requests;
    mapping (address => bool) whitelists;

    event PowerUp(address indexed who, Period period, uint256 amount);
    event PowerDown(address indexed who, Period period, uint256 amount);
    event Upgrade(address indexed who, Period src, Period dest, uint256 amount);
    event Redeemd(address indexed who, uint256 amount);

    modifier onlyGuadge {
        require(msg.sender == guage);
        _;
    }

    modifier onlyWhitelist {
        require(whitelists[msg.sender]);
        _;
    }

    constructor(address _nut, address _guage) {
        console.log("Deploying a NutPower with nut:", _nut);
        nut = _nut;
        guage = _guage;
    }

    function adminSetGuage(address _guage) external onlyOwner {
        guage = _guage;
    }

    function adminSetWhitelist(address _who, bool _tag) external onlyOwner {
        whitelists[_who] = _tag;
    }

    function powerUp(uint256 _amount, Period _period) external {
        require(_amount > 0, "Invalid lock amount");
        IERC20(nut).transferFrom(msg.sender, address(this), _amount);
        powers[msg.sender].free = powers[msg.sender].free.add(_amount.mul(multipier[uint256(_period)]));
        depositInfos[msg.sender][_period].amount = depositInfos[msg.sender][_period].amount.add(_amount);

        emit PowerUp(msg.sender, _period, _amount);
    }

    // _amount: NUT Power
    function powerDown(uint256 _amount, Period _period) external {
        uint256 downNut = _amount.div(uint256(_period) + 1);
        require(_amount > 0, "Invalid unlock NP");
        require(depositInfos[msg.sender][_period].amount >= downNut, "Insufficient free NUT");

        powers[msg.sender].free = powers[msg.sender].free.sub(_amount);
        depositInfos[msg.sender][_period].amount = depositInfos[msg.sender][_period].amount.sub(downNut);
        // Add to redeem request queue
        requests[msg.sender][_period].queue.push(RedeemRequest ({
            amount: downNut,
            claimed: 0,
            startTime: block.timestamp,
            endTime: block.timestamp.add(WEEK.mul(uint256(_period) + 1))
        }));
        emit PowerDown(msg.sender, _period, _amount);
    }

    function upgrade(uint256 _amount, Period _src, Period _dest) external {
        uint256 srcLockedAmount = depositInfos[msg.sender][_src].amount;
        require(_amount > 0 && srcLockedAmount >= _amount, "Invalid upgrade amount");
        require(uint256(_src) < uint256(_dest), 'Invalid period');

        depositInfos[msg.sender][_src].amount = depositInfos[msg.sender][_src].amount.sub(_amount);
        depositInfos[msg.sender][_dest].amount = depositInfos[msg.sender][_dest].amount.add(_amount);
        powers[msg.sender].free = powers[msg.sender].free.add(_amount.mul(multipier[uint256(_dest).sub(uint256(_src))]));

        emit Upgrade(msg.sender, _src, _dest, _amount);
    }

    function redeem() external {
        uint256 avaliableRedeemNut = 0;
        for (uint256 period = 0; period < PERIOD_COUNT; period++) {
            for (uint256 idx = requests[msg.sender][Period(period)].index; idx < requests[msg.sender][Period(period)].queue.length; idx++) {
                uint256 claimable = this._claimableNutOfRequest(requests[msg.sender][Period(period)].queue[idx]);
                requests[msg.sender][Period(period)].queue[idx].claimed = requests[msg.sender][Period(period)].queue[idx].claimed.add(claimable);
                // Ignore requests that has already claimed completely next time.
                if (requests[msg.sender][Period(period)].queue[idx].claimed == requests[msg.sender][Period(period)].queue[idx].amount) {
                    requests[msg.sender][Period(period)].index = idx;
                }

                if (claimable > 0) {
                    avaliableRedeemNut = avaliableRedeemNut.add(claimable);
                }
            }
        }

        require(IERC20(nut).balanceOf(address(this)) > avaliableRedeemNut, "Inceficient balance of NUT");
        IERC20(nut).transfer(msg.sender, avaliableRedeemNut);
        emit Redeemd(msg.sender, avaliableRedeemNut);
    }

    function lock(address _who, uint256 _amount) external onlyWhitelist {
        require(powers[_who].free >= _amount, "Inceficient power to lock");
        powers[_who].free = powers[_who].free.sub(_amount);
        powers[_who].locked = powers[_who].locked.add(_amount);
    }

    function unlock(address _who, uint256 _amount) external onlyWhitelist {
        require(powers[_who].locked >= _amount, "Inceficient power to unlock");
        powers[_who].free = powers[_who].free.add(_amount);
        powers[_who].locked = powers[_who].locked.sub(_amount);
    }

    function name() external pure returns (string memory)  {
        return "Nut Power";
    }

    function symbol() external pure returns (string memory) {
        return "NP";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) external view returns (PowerInfo memory) {
        return powers[account];
    }

    function redeemRequestCountOfPeriod(address _who, Period _period) external view returns (uint256 len) {
        len = requests[_who][_period].queue.length;
        return len;
    }

    function redeemRequestsOfPeriod(address _who, Period _period) public view returns (RedeemRequest[] memory reqs) {
        reqs = requests[_who][_period].queue;
        return reqs;
    }

    function firstRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        req = requests[_who][_period].queue[requests[_who][_period].index];
        return req;
    }

    function lastRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        req = requests[_who][_period].queue[this.redeemRequestCountOfPeriod(_who, _period).sub(1)];
        return req;
    }

    function claimableNut(address _who) external view returns (uint256 amount) {
        for (uint256 period = 0; period < PERIOD_COUNT; period++) {
            for (uint256 idx = requests[_who][Period(period)].index; idx < requests[_who][Period(period)].queue.length; idx++) {
                amount = amount.add(this._claimableNutOfRequest(requests[_who][Period(period)].queue[idx]));
            }
        }
        return amount;
    }

    function _claimableNutOfRequest(RedeemRequest memory _req) public view returns (uint256 amount) {
        amount = _req.amount
                .mul(block.timestamp.sub(_req.startTime))
                .div(_req.endTime.sub(_req.startTime))
                .sub(_req.claimed);

        return amount;
    }
}
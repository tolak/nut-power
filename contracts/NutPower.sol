//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

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

    uint256 public totalLockedNut;
    address private nut;
    address private gauge;

    mapping (address => uint256) private _allowances;

    mapping (address => PowerInfo) powers;
    mapping (address => mapping (Period => uint256)) depositInfos;
    uint256[] multipier = [1, 2, 4, 8, 16, 32, 64];
    mapping (address => mapping (Period => RequestsOfPeriod)) requests;
    mapping (address => bool) whitelists;

    event PowerUp(address indexed who, Period period, uint256 amount);
    event PowerDown(address indexed who, Period period, uint256 amount);
    event Upgrade(address indexed who, Period src, Period dest, uint256 amount);
    event Redeemd(address indexed who, uint256 amount);

    modifier onlyGaudge {
        require(msg.sender == gauge);
        _;
    }

    modifier onlyWhitelist {
        require(whitelists[msg.sender]);
        _;
    }

    constructor(address _nut, address _gauge) {
        console.log("Deploying a NutPower with nut:", _nut);
        nut = _nut;
        gauge = _gauge;
    }

    function adminSetNut(address _nut) external onlyOwner {
        nut = _nut;
    }

    function adminSetGauge(address _gauge) external onlyOwner {
        gauge = _gauge;
    }

    function adminSetWhitelist(address _who, bool _tag) external onlyOwner {
        whitelists[_who] = _tag;
    }

    function powerUp(uint256 _nutAmount, Period _period) external {
        require(_nutAmount > 0, "Invalid lock amount");
        IERC20(nut).transferFrom(msg.sender, address(this), _nutAmount);
        // NUT is locked
        totalLockedNut = totalLockedNut.add(_nutAmount);
        powers[msg.sender].free = powers[msg.sender].free.add(_nutAmount.mul(multipier[uint256(_period)]));
        depositInfos[msg.sender][_period] = depositInfos[msg.sender][_period].add(_nutAmount);

        emit PowerUp(msg.sender, _period, _nutAmount);
    }

    function powerDown(uint256 _npAmount, Period _period) external {
        uint256 downNut = _npAmount.div(uint256(_period) + 1);
        require(_npAmount > 0, "Invalid unlock NP");
        require(depositInfos[msg.sender][_period] >= downNut, "Insufficient free NUT");

        powers[msg.sender].free = powers[msg.sender].free.sub(_npAmount);
        depositInfos[msg.sender][_period] = depositInfos[msg.sender][_period].sub(downNut);
        // Add to redeem request queue
        requests[msg.sender][_period].queue.push(RedeemRequest ({
            amount: downNut,
            claimed: 0,
            startTime: block.timestamp,
            endTime: block.timestamp.add(WEEK.mul(uint256(_period) + 1))
        }));
        emit PowerDown(msg.sender, _period, _npAmount);
    }

    function upgrade(uint256 _nutAmount, Period _src, Period _dest) external {
        uint256 srcLockedAmount = depositInfos[msg.sender][_src];
        require(_nutAmount > 0 && srcLockedAmount >= _nutAmount, "Invalid upgrade amount");
        require(uint256(_src) < uint256(_dest), 'Invalid period');

        depositInfos[msg.sender][_src] = depositInfos[msg.sender][_src].sub(_nutAmount);
        depositInfos[msg.sender][_dest] = depositInfos[msg.sender][_dest].add(_nutAmount);
        powers[msg.sender].free = powers[msg.sender].free.add(
            _nutAmount.mul(
                multipier[uint256(_dest)].sub(multipier[uint256(_src)])
            )
        );

        emit Upgrade(msg.sender, _src, _dest, _nutAmount);
    }

    function redeem() external {
        uint256 avaliableRedeemNut = 0;
        for (uint256 period = 0; period < PERIOD_COUNT; period++) {
            for (uint256 idx = requests[msg.sender][Period(period)].index; idx < requests[msg.sender][Period(period)].queue.length; idx++) {
                uint256 claimable = _claimableNutOfRequest(requests[msg.sender][Period(period)].queue[idx]);
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
        // NUT is free
        totalLockedNut = totalLockedNut.sub(avaliableRedeemNut);
        emit Redeemd(msg.sender, avaliableRedeemNut);
    }

    function lock(address _who, uint256 _npAmount) external onlyWhitelist {
        require(powers[_who].free >= _npAmount, "Inceficient power to lock");
        powers[_who].free = powers[_who].free.sub(_npAmount);
        powers[_who].locked = powers[_who].locked.add(_npAmount);
    }

    function unlock(address _who, uint256 _npAmount) external onlyWhitelist {
        require(powers[_who].locked >= _npAmount, "Inceficient power to unlock");
        powers[_who].free = powers[_who].free.add(_npAmount);
        powers[_who].locked = powers[_who].locked.sub(_npAmount);
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
        len = requests[_who][_period].queue.length - requests[_who][_period].index - 1;
        return len;
    }

    function redeemRequestsOfPeriod(address _who, Period _period) external view returns (RedeemRequest[] memory reqs) {
        reqs = new RedeemRequest[](this.redeemRequestCountOfPeriod(_who, _period));
        for (uint i = requests[_who][_period].index; i < requests[_who][_period].queue.length; i++) {
            RedeemRequest storage req = requests[_who][_period].queue[i];
            reqs[i] = req;
        }
        return reqs;
    }

    function firstRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        if (requests[_who][_period].queue.length > 0) {
            req = requests[_who][_period].queue[requests[_who][_period].index];
        }
        return req;
    }

    function lastRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        if (requests[_who][_period].queue.length > 0) {
            req = requests[_who][_period].queue[requests[_who][_period].queue.length - 1];
        }
        return req;
    }

    function claimableNut(address _who) external view returns (uint256 amount) {
        for (uint256 period = 0; period < PERIOD_COUNT; period++) {
            for (uint256 idx = requests[_who][Period(period)].index; idx < requests[_who][Period(period)].queue.length; idx++) {
                amount = amount.add(_claimableNutOfRequest(requests[_who][Period(period)].queue[idx]));
            }
        }
        return amount;
    }

    function lockedNutOfPeriod(address _who, Period _period) external view returns (uint256 amount) {
        amount = depositInfos[_who][_period];
        return amount;
    }

    function _claimableNutOfRequest(RedeemRequest memory _req) private view returns (uint256 amount) {
        if (block.timestamp >= _req.endTime) {
            amount = _req.amount.sub(_req.claimed);
        } else {
            amount = _req.amount
                    .mul(block.timestamp.sub(_req.startTime))
                    .div(_req.endTime.sub(_req.startTime))
                    .sub(_req.claimed);
        }

        return amount;
    }
}
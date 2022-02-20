//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "hardhat/console.sol";

contract NutPower is Ownable {
    using SafeMath for uint256;

    uint256 constant WEEK = 604800;

    enum Period {
        W1,
        W2,
        W4,
        W8,
        W16,
        W32,
        W64
    }

    struct LockInfo {
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
    mapping (address => mapping (Period => LockInfo)) lockInfos;
    uint256[] multipier = [1, 2, 4, 8, 16, 32, 64];
    mapping (address => mapping (Period => RequestsOfPeriod)) requests;

    event PowerUp(address indexed who, Period period, uint256 amount);
    event PowerDown(address indexed who, Period period, uint256 amount);
    event Upgrade(address indexed who, Period src, Period dest, uint256 amount);
    event Redeemd(address indexed who, uint256 amount);

    modifier onlyGuadge {
        require(msg.sender == guage);
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

    function powerUp(uint256 _amount, Period _period) external {
        require(_amount > 0, "Invalid lock amount");
        IERC20(nut).transferFrom(msg.sender, address(this), _amount);
        powers[msg.sender].free = powers[msg.sender].free.add(_amount.mul(multipier[uint256(_period)]));
        lockInfos[msg.sender][_period].amount = lockInfos[msg.sender][_period].amount.add(_amount);

        emit PowerUp(msg.sender, _period, _amount);
    }

    function powerDown(uint256 _amount, Period _period) external {
        uint256 downPower = _amount.mul(uint256(_period));
        require(_amount > 0, "Invalid unlock amount");
        require(powers[msg.sender].free >= downPower, "Insufficient free NP");

        powers[msg.sender].free = powers[msg.sender].free.sub(downPower);
        // Add to redeem request queue
        requests[msg.sender][_period].queue.push(RedeemRequest ({
            amount: _amount,
            claimed: 0,
            startTime: block.timestamp,
            endTime: block.timestamp
        }));
        emit PowerDown(msg.sender, _period, _amount);
    }

    function upgrade(uint256 _amount, Period _src, Period _dest) external {
        uint256 srcLockedAmount = lockInfos[msg.sender][_src].amount;
        require(_amount > 0 && srcLockedAmount >= _amount, "Invalid upgrade amount");
        require(uint256(_src) < uint256(_dest), 'Invalid period');

        lockInfos[msg.sender][_src].amount = lockInfos[msg.sender][_src].amount.sub(_amount);
        lockInfos[msg.sender][_dest].amount = lockInfos[msg.sender][_dest].amount.add(_amount);
        powers[msg.sender].free = powers[msg.sender].free.add(_amount.mul(multipier[uint256(_dest).sub(uint256(_src))]));

        emit Upgrade(msg.sender, _src, _dest, _amount);
    }

    function redeem() external {
        uint256 avaliableRedeemNut = 0;
        for (Period period = 0; period < 7; period++) {
            RedeemRequest[] memory reqs = requests[msg.sender][period].queue;
            RedeemRequest[] memory newReqs;
            for (uint256 idx = requests[msg.sender][period].index; idx < reqs.length; idx++) {
                uint256 claimable = this._claimableNutOfRequest(reqs[idx]);
                requests[msg.sender][period].queue[idx].claimed = requests[msg.sender][period].queue[idx].claimed.add(claimable);
                // Ignore request that has already claimed completely next time.
                if (requests[msg.sender][period].queue[idx].claimed == requests[msg.sender][period].queue[idx].amount) {
                    requests[msg.sender][period].index = idx;
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

    function redeemRequestCount(address _who) external view returns (uint256 len) {
        for (Period period = 0; period < 7; period++) {
            len = len.add(this.redeemRequestCountOfPeriod(_who, period));
        }
        return len;
    }

    function redeemRequestsOfPeriod(address _who, Period _period) external view returns (RedeemRequest[] memory reqs) {
        reqs = requests[_who][_period].queue;
        return reqs;
    }
    
    function redeemRequests(address _who, Period _period) external view returns (RedeemRequest[] memory reqs) {
        for (Period period = 0; period < 7; period++) {
            reqs = reqs.push(this.RedeemRequestsOfPeriod(_who, period));
        }
        return reqs;
    }

    function firstRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        req = requests[_who][_period].queue[requests[_who][_period].index];
        return req;
    }

    function lastRedeemRequest(address _who, Period _period) external view returns (RedeemRequest memory req) {
        req = requests[_who][_period].queue[this.redeemRequestCount(_period).sub(1)];
        return req;
    }

    function claimableNut(address _who) external view returns (uint256 amount) {
        for (Period period = 0; period < 7; period++) {
            RedeemRequest[] memory reqs = requests[_who][period].queue;
            for (uint256 idx = requests[_who][period].index; idx < reqs.length; idx++) {
                amount = amount.add(this._claimableNutOfRequest(reqs[idx]));
            }
        }
        return amount;
    }

    function _claimableNutOfRequest(RedeemRequest _req) private view returns (uint256 amount) {
        amount = _req.amount
                .mul(block.timestamp.sub(_req.startTime))
                .div(_req.endTime.sub(_req.startTime))
                .sub(_req.claimed);

        return amount;
    }
}
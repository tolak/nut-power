const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BN } = require("bn.js");

const bn1e18 = new BN(10).pow(new BN(18));

describe("NutPower Test", () => {
    let nutpower;
    let nut;
    const WEEK = 604800;
    beforeEach(async () => {
        // Initial accounts
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy NUT;
        const Nut = await ethers.getContractFactory("MintableERC20");
        // Mint 100w NUT to owner
        const _nut = await Nut.deploy("Nutbox Token", "NUT", bn1e18.mul(new BN(1000000)).toString(), owner.address);
        await _nut.deployed();
        nut = _nut;

        // Deploy NutPower
        const NutPower = await ethers.getContractFactory("NutPower");
        const _nutpower = await NutPower.deploy(nut.address);
        await _nutpower.deployed();
        nutpower = _nutpower;

        // Accounts approve NutPower spend NUT
        await nut.mint(addr1.address, bn1e18.mul(new BN(10000)).toString());
        await nut.mint(addr2.address, bn1e18.mul(new BN(10000)).toString());
        await nut.connect(owner).approve(nutpower.address, bn1e18.mul(new BN(10000)).toString());
        await nut.connect(addr1).approve(nutpower.address, bn1e18.mul(new BN(10000)).toString());
        await nut.connect(addr2).approve(nutpower.address, bn1e18.mul(new BN(10000)).toString());
        expect(await nut.allowance(owner.address, nutpower.address)).equal(bn1e18.mul(new BN(10000)).toString());
        expect(await nut.allowance(addr1.address, nutpower.address)).equal(bn1e18.mul(new BN(10000)).toString());
        expect(await nut.allowance(addr2.address, nutpower.address)).equal(bn1e18.mul(new BN(10000)).toString());
    });

    it("Admin methods test", async () => {
        await expect(nutpower.connect(addr1).adminSetNut("0x0000000000000000000000000000000000000000"))
            .revertedWith("Ownable: caller is not the owner")
        await expect(nutpower.connect(addr1).adminSetWhitelist("0x0000000000000000000000000000000000000000", true))
            .revertedWith("Ownable: caller is not the owner")

        await nutpower.connect(owner).adminSetNut(addr1.address);
        expect(await nutpower.nut()).equal(addr1.address);
        await expect(nutpower.connect(addr1).lock(addr1.address, 0))
            .revertedWith("Address is not whitelisted")
    });

    it("Power up test", async () => {
        // addr1 lock 100 NUT for Period.W1
        await nutpower.connect(addr1).powerUp(bn1e18.mul(new BN(100)).toString(), 0);
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(100)).toString());
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100)).toString());

        // addr1 lock 100 NUT for Period.W3
        await nutpower.connect(addr1).powerUp(bn1e18.mul(new BN(100)).toString(), 2);
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(500)).toString());
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(200)).toString());
    });

    it("Power down test", async () => {
        // addr1 power up 100 NUT for Period.W3
        await nutpower.connect(addr1).powerUp(bn1e18.mul(new BN(100)).toString(), 2);
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(400)).toString());
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100)).toString());
        expect(await nutpower.totalIssuedNp()).equal(bn1e18.mul(new BN(400)).toString());

        // addr1 power down  500 NP
        await expect(nutpower.connect(addr1).powerDown(bn1e18.mul(new BN(500)).toString(), 2))
            .revertedWith("Insufficient free NP")
        // addr1 power down 200 NP(half of total NP of addr1)
        await nutpower.connect(addr1).powerDown(bn1e18.mul(new BN(200)).toString(), 2);
        // Total locked nut not changed before redeem
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100)).toString());
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(200)).toString());
        expect(await nutpower.lockedNutOfPeriod(addr1.address, 2)).equal(bn1e18.mul(new BN(50)).toString());
        expect(await nutpower.redeemRequestCountOfPeriod(addr1.address, 2)).equal(1);
        expect(await nutpower.totalIssuedNp()).equal(bn1e18.mul(new BN(200)).toString());
    });

    it("Upgrade test", async () => {
        // addr1 power up 100 NUT for Period.W1
        await nutpower.connect(addr1).powerUp(bn1e18.mul(new BN(100)).toString(), 0);
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(100)).toString());
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100)).toString());

        // addr1 upgrade 50 NUT from Period.W1 to Period.W4
        await expect(nutpower.connect(addr1).upgrade(bn1e18.mul(new BN(50)).toString(), 2, 3))
            .revertedWith("Invalid upgrade amount")
        await nutpower.connect(addr1).upgrade(bn1e18.mul(new BN(50)).toString(), 0, 3);
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100)).toString());
        expect((await nutpower.balanceOf(addr1.address)).free).equal(bn1e18.mul(new BN(450)).toString());
        await expect(nutpower.connect(addr1).upgrade(bn1e18.mul(new BN(50)).toString(), 3, 1))
            .revertedWith("Invalid period")
    });

    it("Redeem test", async () => {
        // addr1 power up 100 NUT for Period.W3
        await nutpower.connect(addr1).powerUp(bn1e18.mul(new BN(100)).toString(), 2);
        // addr1 power down 240 NP, 60 NUT would be released at the end
        await nutpower.connect(addr1).powerDown(bn1e18.mul(new BN(240)).toString(), 2);
        // 1st week of total 4 weeks linear release
        await ethers.provider.send("evm_increaseTime", [WEEK]);
        await ethers.provider.send("evm_mine");
        expect(await nutpower.claimableNut(addr1.address)).equal(bn1e18.mul(new BN(15)).toString());
        // 2nd week of total 4 weeks linear release
        await ethers.provider.send("evm_increaseTime", [WEEK]);
        await ethers.provider.send("evm_mine");
        expect(await nutpower.claimableNut(addr1.address)).equal(bn1e18.mul(new BN(30)).toString());
        // 3rd week of total 4 weeks linear release
        await ethers.provider.send("evm_increaseTime", [WEEK]);
        await ethers.provider.send("evm_mine");
        expect(await nutpower.claimableNut(addr1.address)).equal(bn1e18.mul(new BN(45)).toString());
        // 4th week of total 4 weeks linear release
        await ethers.provider.send("evm_increaseTime", [WEEK]);
        await ethers.provider.send("evm_mine");
        expect(await nutpower.claimableNut(addr1.address)).equal(bn1e18.mul(new BN(60)).toString());

        // Now redeem NUT
        await nutpower.connect(addr1).redeem();
        expect(await nutpower.redeemRequestCountOfPeriod(addr1.address, 2)).equal(0);
        expect(await nutpower.totalLockedNut()).equal(bn1e18.mul(new BN(100-60)).toString());
        expect(await nutpower.claimableNut(addr1.address)).equal(bn1e18.mul(new BN(0)).toString());
    });
});

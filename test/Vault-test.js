const { ethers } = require("hardhat");
const { FakeContract, smock } = require("@defi-wonderland/smock");
const { expect } = require("chai");
const { SignerWithAddress } = require("@nomiclabs/hardhat-ethers/signers");

describe('the big test', async () => {
  let sOHMFake;
  let gOHMFake;
  let treasuryFake;
  let oracleFake;
  let vault;
  let ousd;

  let deployer;
  before( async () => {
        [deployer] = await ethers.getSigners();
        sOHMFake = await smock.fake("IERC20");
        gOHMFake = await smock.fake("IgOHM");
        treasuryFake = await smock.fake("IERC20");
        oracleFake = await smock.fake("IOracle");
        const Vault = await ethers.getContractFactory('OUSDVault'); 
        vault = await Vault.deploy(sOHMFake.address, gOHMFake.address, treasuryFake.address, oracleFake.address);
        const OUSD = await ethers.getContractFactory('OUSD');
        ousd = await OUSD.deploy(vault.address);
  });
  
  it ('deposits collateral', async () => {
    await sOHMFake.connect(deployer).approve(vault.address, 1);
    await expect(vault.connect(deployer).deposit(1, deployer.address, true));
  });
})
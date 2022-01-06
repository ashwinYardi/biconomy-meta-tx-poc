// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  const Farm = await hre.ethers.getContractFactory("Farm");
  const farmInstance = await Farm.deploy(
    "0x766f03e47674608cccf7414f6c4ddf3d963ae394",
    "100",
    "0x77c940F10a7765B49273418aDF5750979718e85f",
    23595875,
    23595875
  );
  await farmInstance.deployed();
  console.log("Farm deployed at " + farmInstance.address);
  await farmInstance.deployTransaction.wait([(confirms = 6)]);

  await hre.run("verify:verify", {
    address: farmInstance.address,
    constructorArguments: [
      "0x766f03e47674608cccf7414f6c4ddf3d963ae394",
      "100",
      "0x77c940F10a7765B49273418aDF5750979718e85f",
      23595875,
      23596875,
    ],
  });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

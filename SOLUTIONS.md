# Solutions

This file contains the analysis and solutions to all challenges

## Unstoppable

There are 2 tokens being used in this example:
    - the ERC-20 token (DVT), the asset of the vault
    - the ERC-4626 vault token (tDVT), the shares of the vault

The Vault contract allows anyone to ask for a FlashLoan of the total number of assets (DVT) that the vault has, by calling `flashLoan()`. However, one of the initial conditions to execute the function can be leveraged to prevent the Vault from providing more flash loans.

```solidity
if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance();
```

This condition is basically expecting the vault to always have an equal amount of shares and assets. `totalSupply` in this case refers to the total number of shares emitted by the vault, and even though `convertToShares()` doesn't make much sense in this context, it will compare the result of that operation with the amount of assets it has (`balanceBefore`). This operation makes sense (sort of) if the vault expects to always have a ratio of 1:1 shares:tokens. However, we can exploit that condition by transferring one token DVT (asset) to the vault, which will make that condition always revert.

**Code**

- [./test/unstoppable/Unstoppable.t.sol](./test/unstoppable/Unstoppable.t.sol)

## Naive receiver

In this challenge, a `NaiveReceiverPool` contract offers flash loans for the whole amount of WETH that it has. A `FlashLoanReceiver` is also deployed with a function that asks for a flash loan to the pool to perform some action. We are tasked with recovering the WETH of both contracts since they are at risk.

This challenge is divided into 2 parts:

1. Recover the WETH from the `FlashLoanReceiver`
2. Recover the WETH from the `NaiveReceiverPool`

### Recover the WETH from the `FlashLoanReceiver`

Looking at the `flashLoan` function of the pool contract, we can see that it always charges a fixed fee of 1 WETH. We also see that we can use any amount as the flash loan (including 0 WETH). Furthermore, the `FlashLoanReceiver` contract has a bug in it where it doesn't check who's the initiator of the flash loan. Meaning that anyone can call `flashLoan` and use the `FlashLoanReceiver` contract as the receiver. Since `FlashLoanReceiver` contract has 10 WETH, we can call `flashLoan` 10 times, specifying the contract as the receiver and an amount of 0 to slowly drain the receiver contract with the fees paid (1 WETH each time). Since the pool contract also has a `multicall()` function, we can just pack all these calls into 1 multicall. That way, all funds will go to the `feeReceiver` account which, turns out, it's also the deployer of the contract and it's the account that also contains the 1000 WETH of the pool contract.

```solidity
bytes memory receiverDrainCalldata = abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", receiver, address(weth), 0, "");
bytes[] memory multicallPayloadOne = new bytes[](10);
for (uint8 i = 0; i < 10; i++) {
    multicallPayloadOne[i] = receiverDrainCalldata;
}
```

### Recover the WETH from the `NaiveReceiverPool`

Now, the pool contract has a special check in the `withdraw()` function. It allows for a trusted forward to also call the pool contract and, when doing so, allows it to specify the real caller at the end of the calldata received (last 20 bytes). Knowing this, and again using the multicall, we can craft a transaction that drains the pool.

We start by crafting a transaction that calls the `withdraw` method to withdraw everything to the recovery address. Since we want to trigger the path where the msg.sender is specified at the end of the calldata, we add the deployer's address at the end:

```solidity
bytes memory poolDrainCallData = abi.encodePacked(abi.encodeWithSignature("withdraw(uint256,address)", pool.deposits(deployer), recovery), deployer);
```

We then add that to a multicall calldata:

```
bytes[] memory multicallPayloadTwo = new bytes[](1);
multicallPayloadTwo[0] = poolDrainCallData;
```

And finally craft the request to send to the forwarder:

```solidity
bytes memory forwarderCallData = abi.encodeWithSignature("multicall(bytes[])", multicallPayloadTwo);
```

We now just need to craft the request object and EIP-712 sign it, to send it to the forwarder, which will forward the call to the pool contract, enter through multicall, and then delegate-call withdraw obtaining the msg.sender from the last 20 bytes of the calldata.

**Code**

- [./test/unstoppable/NaiveReceiver.t.sol](./test/unstoppable/NaiveReceiver.t.sol)

## Truster

This pool offers flash loans of up to 1,000,000 WETH using a non-standard `flashLoan` function. The biggest issue with the contract is that, instead of calling a specific (standard) function in the target contract, it allows for arbitrarily calling any function. We can leverage that to gain privileges over the tokens it has and transfer them to the recovery account.

The method used to recover the funds involves calling the `approve` method on behalf of the token contract and later using `transferFrom` to move the funds to the recovery account.

Since we can only use one transaction to perform both operations, we can craft a simple contract that does that in one function. We could, alternatively, use a multicall contract if it was available.

```solidity
function attack(address recovery) external {
    uint256 poolBalance = token.balanceOf(address(pool));

    bytes memory approveCalldata = abi.encodeWithSignature("approve(address,uint256)", address(this), poolBalance);
    pool.flashLoan(0, address(this), address(token), approveCalldata);
    token.transferFrom(address(pool), recovery, poolBalance);
}
```

**Code**

- [./test/truster/TrusterExploiter.sol](./test/truster/TrusterExploiter.sol)
- [./test/truster/Truster.t.sol](./test/truster/Truster.t.sol)

## SideEntrance

This pool offers Flash Loans of up to the balance it has in ETH, which at the time of this challenge is 100 ETH. When requesting a flash loan, it compares the balance of ETH it has before and after making a call to `execute` in the target contract. However, the balance of the contract is also changed when calling either `deposit` or `withdraw`. Thus, we can use these methods to assign all funds of the contract to ourselves and transfer them to the recovery account.

We first create a contract that has an `attack` function that asks for a flash loan and, in an `execute` function just calls `Pool.deposit` to send the funds back to the pool contract but depositing them in behalf of the exploiter contract. After that, the balance of the pool contract will stay the same, so the flash loan succeeds. We can then call `withdraw` and receive those funds in the contract, to transfer them to the recovery account.

```solidity
function execute() payable external {
    pool.deposit{value: msg.value}();
}

function attack(address recovery) payable external {
    uint256 poolBalance = address(pool).balance;
    pool.flashLoan(poolBalance);
    pool.withdraw();
    (bool success,) = payable(recovery).call{value: poolBalance}("");
    require(success, "Transfer ETH failed");
}

receive() payable external {}
```

**Code**

- [./test/side-entrance/SideEntranceExploiter.sol](./test/side-entrance/SideEntranceExploiter.sol)
- [./test/side-entrance/SideEntrance.t.sol](./test/side-entrance/SideEntrance.t.sol)

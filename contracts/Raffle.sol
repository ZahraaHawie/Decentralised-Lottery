// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

//VRF coordinator is the address of the contract that does the random number verification.
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
//To make our smart contract VRFable
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
//Chainlink keepers
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);
error Raffle__NotEnoughETHEntered();
error Raffle__TransferFailed();
error Raffle__RaffleNotOpen();

/**@title A sample Raffle Contract
 * @author Patrick Collins
 * @notice This contract is for creating a sample raffle contract
 * @dev This implements the Chainlink VRF Version 2
 */

contract Raffle is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type Declarations */
    enum RaffleState {
        OPEN,
        CALCULATING
    } // uint256 0 = OPEN, 1 = CALCULATING,

    /* State Variables */
    //Chainlink VRF variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscrcriptionId;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private immutable i_callbackGasLimit;
    uint32 private constant NUM_WORDS = 1;

    //Lotery Variables
    /* since we gonna set this for one time -> immutable */
    uint256 private i_entranceFee;
    /* we will save this is storage have to be in storage, 
    because we're going to modify this a lot, 
    we're going to be adding and subtracting players all the time */
    address payable[] s_players;
    //payable because if one player wins we have to pay them

    address private s_recentWinner;
    RaffleState private s_raffleState;
    uint256 private s_lastTimeStamp;
    uint256 private immutable i_interval;

    /* Events */
    event RaffleEnter(address indexed player);
    event RequestRaffleWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);

    constructor(
        address vrfCoordinatorV2,
        uint256 entranceFee,
        bytes32 gasLane, //keyhash
        uint64 subscrcriptionId,
        uint32 callbackGasLimit,
        uint256 interval
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_entranceFee = entranceFee;
        i_gasLane = gasLane;
        i_subscrcriptionId = subscrcriptionId;
        i_callbackGasLimit = callbackGasLimit;
        i_interval = interval;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
    }

    //public: Anyone can join | payable: entrancefees
    function enterRaffle() public payable {
        //instead of require( > , "Not enough..")
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players.push(payable(msg.sender));

        //emit an event when we update a dynamic array or mapping
        emit RaffleEnter(msg.sender);
    }

    /**
     * @dev this is the function that the chainlink keeper nodes call
     * they look for the to return true.
     * The following should be true in order to return true & requestRandomWinner:
     * 1. Our time interval should have passed
     * 2. The lottery should have at least one player and have some eath.
     * 3. Then our subscription is funded with LINK
     * 4. The lottery should be in an "open" state. ( So we should create some state variable telling us whether the lottery is open or not)
     */

    /*It's basically going to be checking to see is it time for us to get a random number to
    update the recent winner and to send them all the funds */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        override
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool isOpen = RaffleState.OPEN == s_raffleState;
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool hasPlayers = s_players.length > 0;
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = (timePassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "0x0"); // can we comment this out?
    }

    /**
     * @dev Once `checkUpkeep` is returning `true`, this function is called
     * and it kicks off a Chainlink VRF call to get a random winner.
     */

    /* So in order for us to pick a random winner, we actually have to do two things:
    1: Request the random number| 2. Once we get it, do something wih it 
    Chainlink VRF is a 2 transaction process*/
    //We need this request random nbs automatically happens using chainlink keepers
    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        // require(upkeepNeeded, "Upkeep not needed");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;
        //a unique ID that defines who's requesting this and all this other information.
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, //gasLane: the maximum gas price you are willing to pay for a request in wei
            i_subscrcriptionId, //Id this contract use for funding requests
            REQUEST_CONFIRMATIONS, //confirmations the Chainlink node should wait before responding.
            /*The limit for how much gas to use for the callback request to your contract's fulfillRandomWords() function, 
            this is a good way to protect ourselves from spending way too much gas */
            i_callbackGasLimit,
            NUM_WORDS //this is going to be how many random numbers that we want to get and we want 1
        );
        emit RequestRaffleWinner(requestId);
    }

    /**
     * @dev This is the function that Chainlink VRF node
     * calls to send the money to the random winner.
     */

    /* Since the random number generated could be so big we have to use modulo function
    to allow us pick a winner from our array using this random nb.. Eg (Generated RN: 202, Array of players is 10) */
    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        // s_players size 10
        // randomNumber 202
        // 202 % 10 ? what's doesn't divide evenly into 202?
        // 20 * 10 = 200
        // 2
        // 202 % 10 = 2
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_players = new address payable[](0);
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        (bool success, ) = recentWinner.call{value: address(this).balance}("");
        // require(success, "Transfer failed");
        if (!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recentWinner);
    }

    //since i_entrancefee is private, I have to set a function to allow users to see
    /** Getter Functions */

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }

    function getNumWords() public pure returns (uint256) {
        return NUM_WORDS;
    }

    function getRequestConfirmations() public pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getLastTimeStamp() public view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getInterval() public view returns (uint256) {
        return i_interval;
    }

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }
}

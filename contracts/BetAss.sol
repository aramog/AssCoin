/*
Implements a betting interface for simple wagers:

Bet {
	owner -- creator of the contract that defines its parameters.
	constructor (odds, stake, side) {
		- creates the bet defined by odds and stake.
		- places the message sender to the desired side.
		- sets the owner to message sender.
	}
	addStake(stake) {
		- makes sure contract capacity can still accept stake.
		- message sender stakes on the opposite side of the bet from contract owner.
	}
	execute() {
		- Checks that sender is bet creator (only they can execute)
		- Checks that the contract can be execute (when both sides of the bet are fully subscribed).
		- Runs the random mechanism resolving the bet.
		- Awards the winner the pool of coin.
	}
}
*/

pragma solidity ^0.6.9;

import "./EIP20Interface.sol";

contract BetAss {
	uint256 constant odds_denom = 100; // what we divide odds by for the chance of a true outcome
	uint256 constant MAX_PUB_STAKERS = 100; // what we use to instantiate the array
	
	address payable owner; // the address of the contract creator, will be owner b/c they fully own one side of bet
	uint256 odds; // chance of true outcome --> odds / odds_denom
	
	// Formula to ensure equal odds weighted betting pool:
	// (1 - odds/odds_denom) * true_stake = (odds/odds_denom) * false_stake
	
	// vars for the owner information
	uint256 owner_stake;
	bool owner_funded; // whether the owner has staked their side of the bet.
	
	// vars for the public stakers: call public whoever takes the opposite side of the owner
	uint256 total_public_stake; // total value that the public needs to put on the opposite side of this bet
	mapping (address => uint256) public public_stakes; // mapping to hold the list of all public stakers
	address[] public_stakers; // place to store all addresses that have staked, just keys of above map
	uint256 curr_public_stake; // how much has currently been staked by the public
	bool public_funded; // only true when total_public_stake == curr_public_stake
	
	enum Outcome { OWNER, PUBLIC } // for the 2 possible winners of the contract
	Outcome winner;
	bool executed; // flag after the execute function has been run.
	bool paid; // flag after the winnings have been paid out

	// token that will be what this bet is denominated in
	EIP20Interface token;
	address token_address;

	constructor(
		uint256 _odds, 
		uint256 _stake, // how much the contract owner is staking on their side of the bet
		address _token_address 
	) public {
    	// set the owner of the contract
    	owner = msg.sender;
    	odds = _odds;
    	owner_stake = _stake;
    	// TODO: higher precision calculation
    	total_public_stake = (odds_denom / odds) * owner_stake; 
    	public_stakers = new address[](MAX_PUB_STAKERS);
    	// creates an instance of the token contract to be used throughout the bet contract
    	token_address = _token_address;
    	token = EIP20Interface(_token_address);
    	// does a balance check
    	require(token.balanceOf(owner) > _stake, "Insufficient balance: can't stake more than you have");    	
	}

	/*
	Method must be called by the contract owner. The contract owner must have already given this contract
	the neccessary allowance to stake the entire bet. If successful, funded var becomes true, and now betters
	can stake on the other side of the bet. If not successful, the contract will remain in the unstaked state,
	where no other betters can enter.
	*/
	function fundContract() public returns(bool success) {
		// verifies the sender
		require(msg.sender == owner, "only the contract owner can fund this bet");
		// verifies that contract has sufficient allowance to initiate the transfer
		checkAllowance(owner, address(this), owner_stake);
		// Initiates the transfer
		transferCoin(owner, address(this), owner_stake);
		// only reach this line if the contract has been funded
		owner_funded = true;
		return true;		
	}

	/*
	Will only succeed if stake < token allowance and stake < notowner_stake.
	Adds the message sender to the pool of bets taking the opposite side of the contract
	owner's bet. Payout is proportional to stake percent of total pool.
	*/
	function addStake(uint256 stake) public returns(bool success) {
		// checks that the owner has funded this contract
		// TODO: might not actually need this check, but that's a design decision
		require(owner_funded, "This contract is not accepting public stakes: the owner has not funded it yet");
		// check that the contract has not yet been fully funded by the public
		require(!public_funded, "This contract has already been fully funded by public stakers");
		// checks that there's enough room left in the public money pool
		require(stake <= total_public_stake - curr_public_stake,
				"Requested stake would oversubscribe the bet: stake less.");
		// makes sure stake is nonzero
		require(stake > 0, "Must stake a positive amount of tokens");
		// checks that there is sufficient alloance
		checkAllowance(msg.sender, address(this), stake);
		// initiates the transfer
		transferCoin(msg.sender, address(this), stake);
		// means we succeeded, so add msg.sender to the public stakers
		if (public_stakes[msg.sender] == 0) {
			// means that this sender has not staked before
			public_stakers[public_stakers.length-1] = msg.sender;
		}
		public_stakes[msg.sender] += stake; // maps are 0 initialized, so this is fine\
		curr_public_stake += stake;
		// updates the public_funded var
		if (curr_public_stake == total_public_stake) {
			public_funded = true;
		}
	}

	/*
	Execute the contract in the following steps:
	- Check that the contract can be executed.
	- Run the random number generator.
	- Set winner var to owner or public.
	*/
	function executeBet() public returns(bool outcome) {
		// checks that the owner is executing the contract
		require(msg.sender == owner, "Only the contract owner can execute the contract");
		// make sure that both sides of the bet are funded
		require(owner_funded, "This contract has not been funded by its owner yet");
		require(public_funded, "This contract's public betting pool has not been fully funded yet");
		// Run the RNG, effectively executing the bet
		uint256 rand = randomInt(odds_denom);
		executed = true;
		// By definition, the owner always takes the under.
 		if (rand < odds) {
			// means the owner won
			winner = Outcome.OWNER;
		} else {
			// means the public won
			winner = Outcome.PUBLIC;
		}
		return !(rand < odds); // returns if the owner won the bet
	}

	/*
	The randomness engine of this contract. Will return a pseudo random integer
	in the range [0, max).
	*/
	function randomInt(uint256 max) internal returns (uint256 rand) {
		return uint256(keccak256(abi.encode(block.timestamp, block.difficulty)))%max;
	}

	/*	
	Once the contract has been executed, anyone can call this function to payout
	the winner of the bet.
	*/
	function payoutWinner() public returns (bool success) {
		// check that the contract has been executed
		require(executed, "Must execute the contract before payout");
		// pays out depending on the winner
		uint256 payout = owner_stake + total_public_stake;
		if (winner == Outcome.OWNER) {
			// means the contract owner gets the full balance
			// does the transfer
			transferCoin(address(this), owner, payout);
		} else {
			uint256 contribution;
			uint256 pub_payout;
			for (uint i=0; i < public_stakers.length; i++) {
				// calculates the addresses contribution
				contribution = public_stakes[public_stakers[i]];
				// calculates how much payout they get
				pub_payout = (contribution / total_public_stake) * payout;
				// does the transfer
				transferCoin(address(this), public_stakers[i], pub_payout);
			}
			// pays the first public staker whatever was left over
			uint256 leftover = token.balanceOf(address(this));
			transferCoin(address(this), public_stakers[0], leftover);
		}
		paid = true;
		return true;
	}

	/*
	Self destruct function to run after the bet has been executed and payed out.
	Needs to be run by the contract owner.
	*/
	function closeContract() public returns (bool success) {
		// checks that the call is coming from the contract owner
		require(msg.sender == owner, "Only the owner can close this contract");
		// checks that the contract has already been paid out
		require(paid, "Contract can only be closed after the bet pool has been paid out");
		selfdestruct(owner);
		return true;
	}

	// 
	// TRANSACTION HELPER FUNCTIONS
	//
	/* checks that token allowance from --> to is > min */
	function checkAllowance(address _from, address _to, uint256 min)  internal returns(bool success){
		uint256 allowed = token.allowance(_from, _to);
		require(allowed >= min, "Insufficient allowance for requested stake to be executed");
		return true;
	}

	/* Helper function for doing coin transfers. Includes an error message.*/	
	function transferCoin(address _from, address _to, uint256 amount) internal returns(bool success) {
		// if sending coin from this contract, adds an allowance
		if (_from == address(this)) {
			token.approve(_to, amount);
		}
		bool transferred = token.transferFrom(_from, _to, amount);
		require(transferred, "token transfer not successful");
		return true;
	}

	//
	// VARIABLE GET FUNCTIONS
	//
	/*Returns the amount staker has staked in the public pool.*/
	function getStake(address staker) public view returns(uint256 _stake) {
		return public_stakes[staker];
	}

	function getOdds() public view returns(uint256 _odds) {
		return odds;
	}

	function getOwner() public view returns(address _owner) {
		return owner;
	}

	function getTotalPublicStake() public view returns(uint256 _pub_stake) {
		return total_public_stake;
	}

	function getCurrentPublicStake() public view returns(uint256 _curr_pub_stake) {
		return curr_public_stake;
	}

	function getOwnerFunded() public view returns(bool _owner_funded) {
		return owner_funded;
	}

	function getPublicFunded() public view returns(bool _public_funded) {
		return public_funded;
	}

	function contractAddress() public view returns(address _contract_address) {
		return address(this);
	}

	function tokenAddress() public view returns(address _token_address) {
		return token_address;
	}

	function getWinner() public view returns(bool ownerWon) {
		if (winner == Outcome.OWNER) {
			return true;
		} else {
			return false;
		}
	}
}


// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4; 

// Used on interfaces
import '@openzeppelin/contracts/access/AccessControl.sol';
import "../Tokens/IRAIR-ERC721.sol";
import "../Tokens/IERC2981.sol";

// Parent classes
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

/// @title  Minter Marketplace 
/// @notice Handles the minting of ERC721 RAIR Tokens
/// @author Juan M. Sanchez M.
/// @dev 	Uses AccessControl for the minting mechanisms on other tokens!
contract Minter_Marketplace is OwnableUpgradeable {
	struct offer {
		address contractAddress;
		address nodeAddress;
		uint productIndex;
		uint[] tokenRangeStart;
		uint[] tokenRangeEnd;
		uint[] tokensAllowed;
		uint[] rangePrice;
		string[] rangeName;
	}

	uint16 public constant feeDecimals = 2;

	mapping(address => uint) internal _contractToOffer;

	offer[] offerCatalog;

	address public treasury;
	uint public openSales;
	uint16 public treasuryFee;
	uint16 public nodeFee;

	event AddedOffer(address contractAddress, uint productIndex, uint rangesCreated, uint catalogIndex);
	event UpdatedOffer(address contractAddress, uint offerIndex, uint rangeIndex, uint tokens, uint price, string name);
	event AppendedRange(address contractAddress, uint productIndex, uint offerIndex, uint rangeIndex,  uint startToken, uint endToken, uint price, string name);
	event TokenMinted(address ownerAddress, address contractAddress, uint catalogIndex, uint rangeIndex, uint tokenIndex);
	event SoldOut(address contractAddress, uint catalogIndex, uint rangeIndex);
	event ChangedTreasury(address newTreasury);
	event ChangedTreasuryFee(address treasury, uint16 newTreasuryFee);
	event ChangedNodeFee(uint16 newNodeFee);

	function contractToOffer(address erc721Address) public view returns (uint offerIndex) {
		require(offerCatalog.length > 0 &&
					offerCatalog[_contractToOffer[erc721Address]].contractAddress == erc721Address,
						"Minting Marketplace: Contract address doesn't have an offer associated!");
		return (_contractToOffer[erc721Address]); 
	}

	/// @notice	Constructor
	/// @dev	Should start up with the treasury, node and treasury fee
	/// @param	_treasury		The address of the Treasury
	/// @param	_treasuryFee	Fee given to the treasury every sale (Recommended default: 9%)
	/// @param	_nodeFee		Fee given to the node on every sale (Recommended default: 1%)
	function initialize(address _treasury, uint16 _treasuryFee, uint16 _nodeFee) public initializer {
		treasury = _treasury;
		treasuryFee = _treasuryFee;
		nodeFee = _nodeFee;
		openSales = 0;
	}

	/// @notice	Sets the new treasury address
	/// @dev	Make sure the treasury is a wallet address!
	/// @dev	If the treasury is a contract, make sure it has a receive function!
	/// @param	_newTreasury	New address
	function setTreasuryAddress(address _newTreasury) public onlyOwner {
		treasury = _newTreasury;
		emit ChangedTreasury(_newTreasury);
	}

	/// @notice	Sets the new treasury fee
	/// @param	_newFee	New Fee
	function setTreasuryFee(uint16 _newFee) public onlyOwner {
		treasuryFee = _newFee;
		emit ChangedTreasuryFee(treasury, _newFee);
	}

	/// @notice	Sets the new fee paid to nodes
	/// @param	_newFee	New Fee
	function setNodeFee(uint16 _newFee) public onlyOwner {
		nodeFee = _newFee;
		emit ChangedNodeFee(_newFee);
	}

	/// @notice	Returns the number of collections on the market
	/// @dev	Includes completed collections though
	function getOfferCount() public view returns(uint) {
		return offerCatalog.length;
	}

	/// @notice	Returns the basic information about an offer
	/// @dev	Translates the internal offer schema to individual values
	/// @param	_index		Index of the offer in this contract
	function getOfferInfo(uint _index) public view returns(address contractAddress, uint productIndex, address nodeAddress, uint availableRanges) {
		offer memory selectedOffer = offerCatalog[_index];
		return (
			selectedOffer.contractAddress,
			selectedOffer.productIndex,
			selectedOffer.nodeAddress,
			selectedOffer.rangeName.length
		);
	}

	/// @notice	Returns the information about an offer's range
	/// @dev	Translates the internal offer schema to individual values
	/// @param	offerIndex		Index of the offer in this contract
	/// @param	rangeIndex		Index of the range inside the contract
	function getOfferRangeInfo(uint offerIndex, uint rangeIndex) public view returns(
		address contractAddress,
		uint collectionIndex,
		uint tokenStart,
		uint tokenEnd,
		uint tokensAllowed,
		uint price,
		string memory name) {
		offer memory selectedOffer = offerCatalog[offerIndex];
		return (selectedOffer.contractAddress,
			selectedOffer.productIndex,
			selectedOffer.tokenRangeStart[rangeIndex],
			selectedOffer.tokenRangeEnd[rangeIndex],
			selectedOffer.tokensAllowed[rangeIndex],
			selectedOffer.rangePrice[rangeIndex],
			selectedOffer.rangeName[rangeIndex]);
	}

	/// @notice Makes sure the starting and ending tokens are correct
	/// @param	start 	Starting token
	/// @param	end 	Ending token
	function _validateRangeInfo(uint start, uint end) internal pure {
		require(start < end, "Minting Marketplace: Range's starting token has to be less than the range's ending token!");
	}

	/// @notice Validates that the Minter Marketplace and the message sender have the correct roles inside the ERC721
	/// @dev	Doubles as a view function for anyone wondering if they can mint or if they need to approve the marketplace
	/// @param	tokenAddress 	Address of the token to validate
	function validateRoles(address tokenAddress) public view returns (bool canOffer) {
		require(IAccessControl(tokenAddress).hasRole(bytes32(keccak256("MINTER")), address(this)), "Minting Marketplace: This Marketplace isn't a Minter!");
		require(IAccessControl(tokenAddress).hasRole(bytes32(keccak256("CREATOR")), address(msg.sender)), "Minting Marketplace: Sender isn't the creator!");
		return true;
	}

	/// @notice Inserts a range inside the offer
	/// @param	offerIndex 	Index of the offer to append ranges to
	/// @param	startToken 	Starting token
	/// @param	endToken 	Ending token
	/// @param	price 		Price of that specific range
	/// @param	name 	 	Name of the range
	function _appendOfferRange(
		uint offerIndex,
		uint startToken,
		uint endToken,
		uint price,
		string memory name
	) internal {
		offer storage selectedOffer = offerCatalog[offerIndex];
		selectedOffer.tokenRangeStart.push(startToken);
		selectedOffer.tokenRangeEnd.push(endToken);
		selectedOffer.rangePrice.push(price);
		selectedOffer.tokensAllowed.push((endToken - startToken) + 1);
		selectedOffer.rangeName.push(name);
		emit AppendedRange(
			selectedOffer.contractAddress,
			selectedOffer.productIndex,
			offerIndex,
			selectedOffer.rangeName.length - 1,
			startToken,
			endToken,
			price,
			name);
		openSales++;
	}

	/// @notice	Adds an offer to the market's catalog
	/// @dev	It validates that the collection has mintable tokens left
	/// @dev	It validates that the number of tokens allowed to sell is less or equal than the number of mintable tokens
	/// @param	_tokenAddress		Address of the ERC721
	/// @param	_productIndex		Index of the collection inside the ERC721
	/// @param	_rangeStartToken	Starting token inside the ERC721 (for each range)
	/// @param	_rangeEndToken		Ending token inside the ERC721 (for each range)
	/// @param	_rangePrice			Price of each range (for each range)
	/// @param	_rangeName			Name (for each range)
	/// @param	_nodeAddress		Address of the node to be paid
	function addOffer(
		address _tokenAddress,
		uint _productIndex,
		uint[] calldata _rangeStartToken,
		uint[] calldata _rangeEndToken,
		uint[] calldata _rangePrice,
		string[] calldata _rangeName,
		address _nodeAddress)
	external {
		validateRoles(_tokenAddress);
		if (offerCatalog.length != 0) {
			require(offerCatalog[_contractToOffer[_tokenAddress]].contractAddress == address(0), "Minting Marketplace: An offer already exists!");
		}
		require(_rangeStartToken.length == _rangeEndToken.length &&
					_rangePrice.length == _rangeStartToken.length &&
					_rangeName.length == _rangePrice.length, "Minting Marketplace: Offer's ranges should have the same length!");
		
		(,,uint mintableTokensLeft,) = IRAIR_ERC721(_tokenAddress).getCollection(_productIndex);
		require(mintableTokensLeft > 0, "Minting Marketplace: Cannot mint more tokens from this Product!");
		
		offer storage newOffer = offerCatalog.push();

		newOffer.contractAddress = _tokenAddress;
		newOffer.nodeAddress = _nodeAddress;
		newOffer.productIndex = _productIndex;

		for (uint i = 0; i < _rangeName.length; i++) {
			_validateRangeInfo(_rangeStartToken[i], _rangeEndToken[i]);
			_appendOfferRange(
				offerCatalog.length - 1,
				_rangeStartToken[i],
				_rangeEndToken[i],
				_rangePrice[i],
				_rangeName[i]
			);
		}
		_contractToOffer[_tokenAddress] = offerCatalog.length - 1;
		emit AddedOffer(_tokenAddress, _productIndex, _rangeName.length, offerCatalog.length - 1);
	}

	function updateOfferRange(
		uint offerIndex,
		uint rangeIndex,
		uint startToken,
		uint endToken,
		uint price,
		string calldata name
	) external {
		offer storage selectedOffer = offerCatalog[offerIndex];
		require(endToken <= selectedOffer.tokenRangeEnd[rangeIndex] &&
					startToken >= selectedOffer.tokenRangeStart[rangeIndex],
						'Minting Marketplace: New limits must be within the previous limits!');
		validateRoles(selectedOffer.contractAddress);
		_validateRangeInfo(startToken, endToken);
		selectedOffer.tokensAllowed[rangeIndex] -= (selectedOffer.tokenRangeEnd[rangeIndex] - selectedOffer.tokenRangeStart[rangeIndex]) - (endToken - startToken);
		selectedOffer.tokenRangeStart[rangeIndex] = startToken;
		selectedOffer.tokenRangeEnd[rangeIndex] = endToken;
		selectedOffer.rangePrice[rangeIndex] = price;
		selectedOffer.rangeName[rangeIndex] = name;
		emit UpdatedOffer(selectedOffer.contractAddress, offerIndex, rangeIndex, selectedOffer.tokensAllowed[rangeIndex], price, name);
	}

	function appendOfferRange(
		uint offerIndex,
		uint startToken,
		uint endToken,
		uint price,
		string calldata name
	) public {
		validateRoles(offerCatalog[offerIndex].contractAddress);
		_validateRangeInfo(startToken, endToken);
		_appendOfferRange(
			offerIndex,
			startToken,
			endToken,
			price,
			name
		);
	}

	function appendOfferRangeBatch(
		uint offerIndex,
		uint[] memory startTokens,
		uint[] memory endTokens,
		uint[] memory prices,
		string[] memory names
	) public {
		require(startTokens.length == endTokens.length &&
					prices.length == startTokens.length &&
					names.length == prices.length, "Minting Marketplace: Offer's ranges should have the same length!");
		validateRoles(offerCatalog[offerIndex].contractAddress);
		for (uint i = 0; i < names.length; i++) {
			_validateRangeInfo(startTokens[i], endTokens[i]);
			_appendOfferRange(
				offerIndex,
				startTokens[i],
				endTokens[i],
				prices[i],
				names[i]
			);
		}
	}
	
	/// @notice	Receives funds and mints a new token for the sender
	/// @dev	It validates that the Marketplace is still a minter
	/// @dev	It splits the funds in 3 ways
	/// @dev	It validates that the ERC721 token supports the interface for royalties and only then, it will give the funds to the creator
	/// @dev	If the ERC721 collection doesn't have any mintable tokens left, it will revert using the ERC721 error, not in the marketplace!
	/// @param	catalogIndex		Index of the sale within the catalog
	/// @param	rangeIndex			Index of the range within the offer
	/// @param	internalTokenIndex	Index of the token within the range
	function buyToken(uint catalogIndex, uint rangeIndex, uint internalTokenIndex) payable public {
		offer storage selectedCollection = offerCatalog[catalogIndex];
		require(selectedCollection.contractAddress != address(0), "Minting Marketplace: Invalid Collection Selected!");
		require((selectedCollection.tokensAllowed.length > rangeIndex), "Minting Marketplace: Invalid range!");
		require((selectedCollection.tokensAllowed[rangeIndex] > 0), "Minting Marketplace: Cannot mint more tokens for this range!");
		require(selectedCollection.tokenRangeStart[rangeIndex] <= internalTokenIndex &&
				internalTokenIndex <= selectedCollection.tokenRangeEnd[rangeIndex],
					"Minting Marketplace: Token doesn't belong in that offer range!");
		require(msg.value >= selectedCollection.rangePrice[rangeIndex], "Minting Marketplace: Insuficient Funds!");
		
		address creatorAddress;
		uint256 amount;

		bool hasFees = IERC2981(selectedCollection.contractAddress).supportsInterface(type(IERC2981).interfaceId);
		
		if (hasFees) {
			(creatorAddress, amount,) = IRAIR_ERC721(selectedCollection.contractAddress).royaltyInfo(0, selectedCollection.rangePrice[rangeIndex], bytes(selectedCollection.rangeName[rangeIndex]));
			payable(creatorAddress).transfer(selectedCollection.rangePrice[rangeIndex] * (100000 - (treasuryFee + nodeFee)) / 100000);
		}

		payable(msg.sender).transfer(msg.value - selectedCollection.rangePrice[rangeIndex]);
		payable(treasury).transfer((selectedCollection.rangePrice[rangeIndex] * treasuryFee) / 100000);
		payable(selectedCollection.nodeAddress).transfer((selectedCollection.rangePrice[rangeIndex] * nodeFee) / 100000);
		selectedCollection.tokensAllowed[rangeIndex]--;
		if (selectedCollection.tokensAllowed[rangeIndex] == 0) {
			openSales--;
			emit SoldOut(selectedCollection.contractAddress, catalogIndex, rangeIndex);
		}
		IRAIR_ERC721(selectedCollection.contractAddress).mint(msg.sender, selectedCollection.productIndex, internalTokenIndex);
		emit TokenMinted(msg.sender, selectedCollection.contractAddress, catalogIndex, rangeIndex, internalTokenIndex);
	}
}
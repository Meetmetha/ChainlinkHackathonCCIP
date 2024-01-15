pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ERC20 {
    function decimals() external view returns (uint8);
}

contract depositByCCIP is Ownable {

    constructor(address _router, address _link, address _destinationReciever, uint64 _destinationChainbyChainlink) {
        ChainlinkRouter = IRouterClient(_router);
        ChalinlinkLinkToken = LinkTokenInterface(_link);
        destinationReciever = _destinationReciever;
        destinationChainbyChainlink = _destinationChainbyChainlink;
    }

    // Mapping and Struct
    mapping(address => TokenConfig) public tokenConfigs;
    mapping(uint256 => Deposit) public deposits;
    uint256 public nextDepositId;
    struct TokenConfig {
        bool isSupported;
        uint256 minDeposit;
        address datafeedchalinlink;
        int defaultPrice; // 8 decimal
    }
    struct Deposit {
        address depositFor;
        address user;
        address token;
        uint256 amount;
    }

    // Destination Configs 
    address public destinationReciever;
    uint64 public destinationChainbyChainlink;
    event deposited(address depositFor,address depositor,uint256 USDvalue);

    // ChalinkLink Config for this Contract
    IRouterClient public ChainlinkRouter;
    LinkTokenInterface public  ChalinlinkLinkToken;
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    event MessageSent(bytes32 indexed messageId,uint64 indexed destinationChainSelector,address receiver,address depositor,uint256 amount,address feeToken, uint256 fees);

    // Owner Functions
    function setTokenConfig(address token,uint256 minDeposit, address datafeed,int defaultPrice) external  onlyOwner {
        tokenConfigs[token] = TokenConfig(true,minDeposit,datafeed,defaultPrice);
    }

    function setdestinationChainbyChainLink(uint64 _destinationChainID) external  onlyOwner {
        destinationChainbyChainlink = _destinationChainID;
    }

    function setLinkToken(address _tokenLink) external  onlyOwner {
        ChalinlinkLinkToken = LinkTokenInterface(_tokenLink);
    }

    function setChainlinkRouter(address _router) external  onlyOwner {
        ChainlinkRouter = IRouterClient(_router);
    }

    function setDestinationReciever(address _destinationReciever) external  onlyOwner {
        destinationReciever = _destinationReciever;
    }

    // User Functions
    function depositCollateral(address depositFor, address token, uint256 amount) external  {
        require(tokenConfigs[token].isSupported, "Token not supported");
        require(amount >= tokenConfigs[token].minDeposit, "Deposit too low");
        require(IERC20(token).allowance(_msgSender(), address(this)) >= amount, "Insufficient allowance");
        IERC20(token).transferFrom(_msgSender(), address(this), amount);
        uint256 depositID = nextDepositId;
        nextDepositId++;
        deposits[depositID] = Deposit(depositFor,_msgSender(),token,amount);
        uint256 USDvalue = (amount * uint256(getAssetPrice(token))) / (10**ERC20(token).decimals());
        emit deposited(depositFor,_msgSender(), USDvalue);
        _sendViaChainlinkCCIP(depositFor,_msgSender(), USDvalue);
    }

    // Internal Function
    function _sendViaChainlinkCCIP(
        address depositFor,
        address depositor,
        uint256 USDvalue
    ) internal returns (bytes32 messageId) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReciever), // ABI-encoded receiver address
            data: abi.encode(depositFor,depositor,USDvalue), // ABI-encoded Data
            tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array indicating no tokens are being sent
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit and non-strict sequencing mode
                Client.EVMExtraArgsV1({gasLimit: 200_000, strict: false})
            ),
            // Set the feeToken  address, indicating LINK will be used for fees
            feeToken: address(ChalinlinkLinkToken)
        });

        // Get the fee required to send the message
        uint256 fees = ChainlinkRouter.getFee(
            destinationChainbyChainlink,
            evm2AnyMessage
        );

        if (fees > ChalinlinkLinkToken.balanceOf(address(this)))
            revert NotEnoughBalance(ChalinlinkLinkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        ChalinlinkLinkToken.approve(address(ChainlinkRouter), fees);

        // Send the message through the router and store the returned message ID
        messageId = ChainlinkRouter.ccipSend(destinationChainbyChainlink, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(
            messageId,
            destinationChainbyChainlink,
            destinationReciever,
            depositor,
            USDvalue,
            address(ChalinlinkLinkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    function getAssetPrice(address token) internal view returns (int){
        if(tokenConfigs[token].datafeedchalinlink != address(0)){
            AggregatorV3Interface priceFeed = AggregatorV3Interface(tokenConfigs[token].datafeedchalinlink);
            (,int price,,,) = priceFeed.latestRoundData();
            return price;
        }
        else{
            return tokenConfigs[token].defaultPrice; 
        }
    }

    function recoverEther() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function recoverTokens(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(owner(), token.balanceOf(address(this)));
    }

    fallback() external payable {}
    receive() external payable {}

    
}
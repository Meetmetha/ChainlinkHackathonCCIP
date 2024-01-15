pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ERC20 {
    function decimals() external view returns (uint8);
}

interface nativeDepositor {
    function depositNative(address depositFor,address depositor,uint256 amount,uint64 chainID) external;
}

contract DepositNative is Ownable {

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

    address public nativeDepositAddress;
    uint64 public destChain = 12532609583862916517;
    event deposited(address depositFor,address depositor,uint256 USDvalue);

    // Owner Functions
    function setTokenConfig(address token,uint256 minDeposit, address datafeed,int defaultPrice) external  onlyOwner {
        tokenConfigs[token] = TokenConfig(true,minDeposit,datafeed,defaultPrice);
    }

    function setNativeDepositAddress(address _nativeDepositAddress) external  onlyOwner {
        nativeDepositAddress = _nativeDepositAddress;
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
        nativeDepositor(nativeDepositAddress).depositNative(depositFor,_msgSender(),USDvalue,destChain);
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
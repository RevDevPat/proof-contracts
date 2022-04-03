// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


interface IBURNER {
    function burnEmUp() external payable;    
}

 interface IUniswapV2Factory {
     function createPair(address tokenA, address tokenB) external returns (address pair);
 }
 
 interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
     function factory() external pure returns (address);
     function WETH() external pure returns (address);
     function addLiquidityETH(
         address token,
         uint amountTokenDesired,
         uint amountTokenMin,
         uint amountETHMin,
         address to,
         uint deadline
     ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidityETH(
      address token,
      uint liquidity,
      uint amountTokenMin,
      uint amountETHMin,
      address to,
      uint deadline
    ) external returns (uint amountToken, uint amountETH);     
 }

interface ITeamFinanceLocker {
        function lockTokens(address _tokenAddress, address _withdrawalAddress, uint256 _amount, uint256 _unlockTime) external payable returns (uint256 _id);
}

interface ITokenCutter {
    function swapTradingStatus() external;       
    function setLaunchedAt() external;       
    function cancelToken() external;       
}

library Fees {
    struct allFees {
        uint256 taxFee;
        uint256 devFee;
    }
}

contract TokenCutter is Context, IERC20, IERC20Metadata  {
    using SafeMath for uint256;

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private constant MAX = ~uint256(0);

    uint256 private _tTotal;
    uint256 private _rTotal;
    uint256 private _tFeeTotal;

    string private _name;
    string private _symbol;
    uint8 private constant _decimals = 9;


    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ZERO = 0x0000000000000000000000000000000000000000;
    address payable public hldBurnerAddress;
    address public hldAdmin;

    mapping (address => bool) public isFeeExempt;
    mapping (address => bool) public isTxLimitExempt;

    uint256 public launchedAt;
    uint256 public _hldFee = 2;

    uint256 public _taxFee;
    uint256 public _devFee;
    uint256 public totalFee;
    uint256 private _previousTaxFee = _taxFee;
    uint256 private _previousdevFee = _devFee;

    uint256 private _hldETHpercent = 20;
    uint256 private _devETHpercent = 80;

    IUniswapV2Router02 public router;
    address public pair;
    address public factory;
    address public tokenOwner;
    address payable public devWallet;

    bool inSwapAndLiquify;
    bool public tradingStatus = true;
    bool private _noTaxMode = false;

    mapping (address => bool) private bots;    

    uint256 public _maxTxAmount;
    
    constructor(string memory tokenName, string memory tokenSymbol, uint256 initialSupply, address owner
                ,address routerAddress, address initialHldAdmin, address initialHldBurner, Fees.allFees memory fees) {

        _name = tokenName;
        _symbol = tokenSymbol;
        _tTotal += initialSupply;
        _rTotal = (MAX - (MAX % _tTotal));
        _rOwned[_msgSender()] += _rTotal;      

        _maxTxAmount = initialSupply;

        router = IUniswapV2Router02(routerAddress);
        pair = IUniswapV2Factory(router.factory()).createPair(router.WETH(), address(this));

        _allowances[address(this)][address(router)] = MAX;

        factory = msg.sender;

        isFeeExempt[address(this)] = true;
        isFeeExempt[factory] = true;

        isTxLimitExempt[owner] = true;
        isTxLimitExempt[pair] = true;
        isTxLimitExempt[factory] = true;
        isTxLimitExempt[DEAD] = true;
        isTxLimitExempt[ZERO] = true; 

        _devFee = fees.devFee;
        _taxFee = fees.taxFee;

        totalFee = _devFee.add(_hldFee);


        tokenOwner = owner;
        devWallet = payable(owner);
        hldBurnerAddress = payable(initialHldBurner);
        hldAdmin = initialHldAdmin;
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    modifier onlyHldAdmin() {
        require(hldAdmin == _msgSender(), "Ownable: caller is not the hldAdmin");
        _;
    }

    modifier onlyOwner() {
        require(tokenOwner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    modifier onlyFactory() {
        require(factory == _msgSender(), "Ownable: caller is not the factory");
        _;
    }

    //hldAdmin functions
    function updateHldAdmin(address newAdmin) public virtual onlyHldAdmin {     
        hldAdmin = newAdmin;
    }

    function updateHldBurnerAddress(address newhldBurnerAddress) public virtual onlyHldAdmin {     
        hldBurnerAddress = payable(newhldBurnerAddress);
    }    
    

    function setBots(address[] memory bots_) external onlyHldAdmin {
        for (uint i = 0; i < bots_.length; i++) {
            bots[bots_[i]] = true;
        }
    }

        
    //Factory functions
    function swapTradingStatus() public onlyFactory {
        tradingStatus = !tradingStatus;
    }

    function setLaunchedAt() public onlyFactory {
        require(launchedAt == 0, "already launched");
        launchedAt = block.timestamp;
    }          
 
    function cancelToken() public onlyFactory {
        isFeeExempt[address(router)] = true;
        isTxLimitExempt[address(router)] = true;
        isTxLimitExempt[tokenOwner] = true;
        tradingStatus = true;
    }         
 
    //Owner functions
    function changeFees(uint256 dev, uint256 tax) external onlyOwner {
        require(dev <= 5, "dev cannot take more than 5%");
        require(tax <= 10, "tax cannot take more than 10%");        
        _devFee = dev; 
        _taxFee = tax;     
    } 

    function reduceHldFee() external onlyOwner {
        require(_hldETHpercent == 20, "!already reduced");                
        require(launchedAt != 0, "!launched");        
        require(block.timestamp >= launchedAt + 72 hours, "too soon");

        _hldETHpercent = 10;
        _devETHpercent = 90;
    }   

    function changeTxLimit(uint256 newLimit) external onlyOwner {
        require(launchedAt != 0, "!launched");
        require(block.timestamp >= launchedAt + 24 hours, "too soon");
        _maxTxAmount = newLimit;
    }
    
    function changeIsFeeExempt(address holder, bool exempt) external onlyOwner {
        isFeeExempt[holder] = exempt;
    }

    function changeIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        require(launchedAt != 0, "!launched");        
        require(block.timestamp >= launchedAt + 24 hours, "too soon");        
        isTxLimitExempt[holder] = exempt;
    }


    function setDevWallet(address payable newDevWallet) external onlyOwner {
        devWallet = payable(newDevWallet);
    } 

    function changeSwapBackSettings(bool enableSwapBack) external onlyOwner {
        swapAndLiquifyEnabled  = enableSwapBack;
    }

    function delBot(address notbot) external onlyOwner {
        bots[notbot] = false;
    }       

    function name() public view override returns (string memory) {
        return _name;
    }
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }
    function balanceOf(address account) public view virtual override returns (uint256) {
        return tokenFromReflection(_rOwned[account]);
    }
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }
    function tokenFromReflection(uint256 rAmount) private view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }
    function removeAllFee() private {
        if(_taxFee == 0 && _devFee == 0) return;
        _previousTaxFee = _taxFee;
        _previousdevFee = _devFee;
        _taxFee = 0;
        _devFee = 0;
    }
    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _devFee = _previousdevFee;
    }
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, _allowances[owner][spender] + addedValue);
        return true;
    }
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = _allowances[owner][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        if(sender != tokenOwner && recipient != tokenOwner && !isTxLimitExempt[recipient]) {
            require(amount <= _maxTxAmount || isTxLimitExempt[sender], "tx");
            require(!bots[sender] && !bots[recipient]);
            
            if(sender == pair && recipient != address(router) && !isFeeExempt[recipient]) {
                require(tradingStatus, "!trading");
            }
            uint256 contractTokenBalance = balanceOf(address(this));

            if(!inSwapAndLiquify && sender != pair && tradingStatus) {
                if(contractTokenBalance > 0) {
                    if(contractTokenBalance > balanceOf(pair).mul(5).div(100)) {
                        contractTokenBalance = balanceOf(pair).mul(5).div(100);
                    }
                    swapTokensForEth(contractTokenBalance);
                }
            }
        }
        bool takeFee = true;

        if(isFeeExempt[sender] || isFeeExempt[recipient] || _noTaxMode){
            takeFee = false;
        }
        
        _tokenTransfer(sender,recipient,amount,takeFee);
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if(!takeFee)
            removeAllFee();
        _transferStandard(sender, recipient, amount);
        if(!takeFee)
            restoreAllFee();
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _takeDev(uint256 tDev) private {
        uint256 currentRate =  _getRate();
        uint256 rDev = tDev.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rDev);
    }


    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tDev) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount); 
        _takeDev(tDev);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tDev) = _getTValues(tAmount, _taxFee, _devFee);
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tDev, currentRate);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tDev);
    }

    function _getTValues(uint256 tAmount, uint256 taxFee, uint256 devFee) private pure returns (uint256, uint256, uint256) {
        uint256 tFee = tAmount.mul(taxFee).div(100);
        uint256 tDev = tAmount.mul(devFee).div(100);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tDev);
        return (tTransferAmount, tFee, tDev);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        if(rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tDev, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rDev = tDev.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rDev);
        return (rAmount, rTransferAmount, rFee);
    }

    function swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountETH = address(this).balance;
        uint256 devBalance = amountETH.mul(_devETHpercent).div(100);
        uint256 hldBalance = amountETH.mul(_hldETHpercent).div(100); 

        if(amountETH > 0){
            IBURNER(hldBurnerAddress).burnEmUp{value: hldBalance}();            
            devWallet.transfer(devBalance);
        }      
    }

    receive() external payable { }

}


contract proofTokenFactory is Ownable {

    address ZERO = 0x0000000000000000000000000000000000000000;    

    struct proofToken {
        bool status;
        address pair;
        address owner;
        uint256 unlockTime; 
        uint256 lockId;       
    }

    mapping (address => proofToken) public validatedPairs;

    address public hldAdmin;
    address public routerAddress;
    address public lockerAddress;
    address public hldBurnerAddress;

    event TokenCreated(address _address);

    constructor(address initialRouterAddress, address initialHldBurner, address initialLockerAddress) {
        routerAddress = initialRouterAddress;
        hldBurnerAddress = initialHldBurner;
        lockerAddress = initialLockerAddress;
        hldAdmin = msg.sender;
    }

    function createToken(string memory tokenName, string memory tokenSymbol, uint256 initialSupply,
                    uint256 initialReflectionFee,
                    uint256 initialDevFee, uint256 unlockTime) external payable {
        require(unlockTime >= block.timestamp + 30 days, "unlock under 30 days");
        require(msg.value >= 0.2 ether, "not enough liquidity");

        //create token    
        Fees.allFees memory fees = Fees.allFees(initialDevFee, initialReflectionFee);
        TokenCutter newToken = new TokenCutter(tokenName, tokenSymbol, initialSupply, msg.sender, routerAddress, hldAdmin, hldBurnerAddress, fees);
        emit TokenCreated(address(newToken));

        //add liquidity
        newToken.approve(routerAddress, type(uint256).max);        
        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        router.addLiquidityETH{ value: msg.value }(address(newToken), newToken.balanceOf(address(this)), 0,0, address(this), block.timestamp);

        // disable trading
        newToken.swapTradingStatus();

        validatedPairs[address(newToken)] = proofToken(false, newToken.pair(), msg.sender, unlockTime, 0);
    }

    function finalizeToken(address tokenAddress) public payable {
        require(validatedPairs[tokenAddress].owner == msg.sender, "!owner");
        require(validatedPairs[tokenAddress].status == false, "validated");

        address _pair = validatedPairs[tokenAddress].pair;
        uint256 _unlockTime = validatedPairs[tokenAddress].unlockTime;
        IERC20(_pair).approve(lockerAddress, type(uint256).max);        

        uint256 lpBalance = IERC20(_pair).balanceOf(address(this));        

        uint256 _lockId = ITeamFinanceLocker(lockerAddress).lockTokens{value: msg.value}(_pair, msg.sender, lpBalance, _unlockTime);
        validatedPairs[tokenAddress].lockId = _lockId;

        //enable trading
        ITokenCutter(tokenAddress).swapTradingStatus(); 
        ITokenCutter(tokenAddress).setLaunchedAt();

        validatedPairs[tokenAddress].status = true;

    }

    function cancelToken(address tokenAddress) public {
        require(validatedPairs[tokenAddress].owner == msg.sender, "!owner");
        require(validatedPairs[tokenAddress].status == false, "validated");

        address _pair = validatedPairs[tokenAddress].pair;
        address _owner = validatedPairs[tokenAddress].owner;

        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        IERC20(_pair).approve(routerAddress, type(uint256).max);   
        uint256 _lpBalance = IERC20(_pair).balanceOf(address(this));

        // enable transfer and allow router to exceed tx limit to remove liquidity
        ITokenCutter(tokenAddress).cancelToken();
        router.removeLiquidityETH(address(tokenAddress), _lpBalance, 0,0, _owner, block.timestamp);

        // disable transfer of token
        ITokenCutter(tokenAddress).swapTradingStatus();

        delete validatedPairs[tokenAddress];
    }    

    function setLockerAddress(address newlockerAddress) external onlyOwner {
        lockerAddress = newlockerAddress;
    }     

    function setRouterAddress(address newRouterAddress) external onlyOwner {
        routerAddress = payable(newRouterAddress);
    }    

    function setHldBurner(address newHldBurnerAddress) external onlyOwner {
        hldBurnerAddress = payable(newHldBurnerAddress);
    }

    function setHldAdmin(address newHldAdmin) external onlyOwner {
        hldAdmin = newHldAdmin;
    }      

}

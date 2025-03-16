module sui_predict::yield {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui_predict::betting_nft::{Self, BettingNFT};
    use std::string::{Self, String};
    use std::option::{Self, Option};
    
    // Error codes
    const EStrategyNotActive: u64 = 0;
    const EInvalidWithdrawalAmount: u64 = 1;
    const EUnauthorized: u64 = 2;
    const ENoBettingNFTFound: u64 = 3;
    const EYieldAlreadyEnabled: u64 = 4;
    const EInvalidRiskLevel: u64 = 5;
    
    // Risk levels
    const RISK_LEVEL_LOW: u8 = 1;
    const RISK_LEVEL_MEDIUM: u8 = 2;
    const RISK_LEVEL_HIGH: u8 = 3;
    
    // YieldStrategy structure
    struct YieldStrategy has key {
        id: UID,
        provider: String,
        total_deposited: u64,
        current_yield_rate: u64, // in basis points (e.g., 500 = 5% APY)
        risk_level: u8, // 1: Low, 2: Medium, 3: High
        active: bool,
        last_harvest_time: u64,
        protocol_adapter: String, // Implementation-specific adapter name
        strategy_params: String, // JSON string with strategy parameters
        treasury_fee: u64, // in basis points (e.g., 1000 = 10%)
    }
    
    // User's yield allocation
    struct UserYieldAllocation has key, store {
        id: UID,
        nft_id: ID,
        strategy_id: ID,
        amount: u64,
        deposit_time: u64,
        last_claimed_time: u64,
        claimed_yield: u64,
    }
    
    // Treasury to collect yield fees
    struct YieldTreasury has key {
        id: UID,
        balance: Balance<SUI>,
    }
    
    // Events
    struct StrategyRegistered has copy, drop {
        strategy_id: ID,
        provider: String,
        risk_level: u8,
        yield_rate: u64,
    }
    
    struct YieldDeposited has copy, drop {
        allocation_id: ID,
        nft_id: ID,
        strategy_id: ID,
        amount: u64,
        user: address,
    }
    
    struct YieldWithdrawn has copy, drop {
        allocation_id: ID,
        nft_id: ID,
        strategy_id: ID,
        amount: u64,
        yield_amount: u64,
        user: address,
    }
    
    struct YieldHarvested has copy, drop {
        strategy_id: ID,
        total_yield: u64,
        treasury_fee: u64,
    }
    
    // Initialize module with a treasury
    fun init(ctx: &mut TxContext) {
        transfer::share_object(
            YieldTreasury {
                id: object::new(ctx),
                balance: balance::zero(),
            }
        );
    }
    
    // Register a new yield strategy
    public entry fun register_strategy(
        provider: vector<u8>,
        current_yield_rate: u64,
        risk_level: u8,
        protocol_adapter: vector<u8>,
        strategy_params: vector<u8>,
        treasury_fee: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate risk level
        assert!(risk_level >= RISK_LEVEL_LOW && risk_level <= RISK_LEVEL_HIGH, EInvalidRiskLevel);
        
        // Create the strategy
        let strategy = YieldStrategy {
            id: object::new(ctx),
            provider: string::utf8(provider),
            total_deposited: 0,
            current_yield_rate,
            risk_level,
            active: true,
            last_harvest_time: clock::timestamp_ms(clock),
            protocol_adapter: string::utf8(protocol_adapter),
            strategy_params: string::utf8(strategy_params),
            treasury_fee,
        };
        
        // Emit strategy registered event
        event::emit(StrategyRegistered {
            strategy_id: object::id(&strategy),
            provider: string::utf8(provider),
            risk_level,
            yield_rate: current_yield_rate,
        });
        
        // Share the strategy object
        transfer::share_object(strategy);
    }
    
    // Enable yield generation for a betting NFT
    public entry fun enable_yield(
        nft: &mut BettingNFT,
        strategy: &mut YieldStrategy,
        amount: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Ensure strategy is active
        assert!(strategy.active, EStrategyNotActive);
        
        // Verify NFT yield is not already enabled
        assert!(!betting_nft::is_yield_enabled(nft), EYieldAlreadyEnabled);
        
        let deposit_amount = coin::value(&amount);
        
        // Create allocation
        let allocation = UserYieldAllocation {
            id: object::new(ctx),
            nft_id: object::id(nft),
            strategy_id: object::id(strategy),
            amount: deposit_amount,
            deposit_time: clock::timestamp_ms(clock),
            last_claimed_time: clock::timestamp_ms(clock),
            claimed_yield: 0,
        };
        
        // Update strategy total
        strategy.total_deposited = strategy.total_deposited + deposit_amount;
        
        // Enable yield on NFT
        betting_nft::set_yield_enabled(nft, true);
        betting_nft::set_yield_strategy_id(nft, object::id(strategy));
        
        // Emit deposit event
        event::emit(YieldDeposited {
            allocation_id: object::id(&allocation),
            nft_id: object::id(nft),
            strategy_id: object::id(strategy),
            amount: deposit_amount,
            user: tx_context::sender(ctx),
        });
        
        // Here we would actually deposit into the DeFi protocol
        // For this demo, we'll just handle the coin in our module
        
        // Share the allocation object
        transfer::share_object(allocation);
    }
    
    // Claim yield from a betting NFT
    public entry fun claim_yield(
        nft: &mut BettingNFT,
        allocation: &mut UserYieldAllocation,
        strategy: &mut YieldStrategy,
        treasury: &mut YieldTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify allocation matches the NFT
        assert!(allocation.nft_id == object::id(nft), ENoBettingNFTFound);
        
        // Calculate yield
        let current_time = clock::timestamp_ms(clock);
        let time_diff_seconds = (current_time - allocation.last_claimed_time) / 1000;
        
        // APY to per-second rate: APY / (365 * 24 * 60 * 60)
        let per_second_rate = strategy.current_yield_rate / 31536000;
        
        // Calculate yield: principal * rate * time
        let yield_amount = (allocation.amount * per_second_rate * time_diff_seconds) / 10000;
        
        // Calculate treasury fee
        let fee_amount = (yield_amount * strategy.treasury_fee) / 10000;
        let user_yield = yield_amount - fee_amount;
        
        // Update allocation
        allocation.last_claimed_time = current_time;
        allocation.claimed_yield = allocation.claimed_yield + user_yield;
        
        // Here we would actually withdraw from the DeFi protocol
        // For this demo, we'll just mint new coins
        
        // Transfer yield to user
        let yield_coin = coin::mint_for_testing<SUI>(user_yield, ctx);
        transfer::transfer(yield_coin, tx_context::sender(ctx));
        
        // Transfer fee to treasury
        let fee_coin = coin::mint_for_testing<SUI>(fee_amount, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
    }
    
    // Withdraw funds from yield generation
    public entry fun withdraw_yield(
        nft: &mut BettingNFT,
        allocation: &mut UserYieldAllocation,
        strategy: &mut YieldStrategy,
        treasury: &mut YieldTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify allocation matches the NFT
        assert!(allocation.nft_id == object::id(nft), ENoBettingNFTFound);
        
        // Calculate yield (same as claim_yield)
        let current_time = clock::timestamp_ms(clock);
        let time_diff_seconds = (current_time - allocation.last_claimed_time) / 1000;
        let per_second_rate = strategy.current_yield_rate / 31536000;
        let yield_amount = (allocation.amount * per_second_rate * time_diff_seconds) / 10000;
        
        // Calculate treasury fee
        let fee_amount = (yield_amount * strategy.treasury_fee) / 10000;
        let user_yield = yield_amount - fee_amount;
        
        // Update strategy total
        strategy.total_deposited = strategy.total_deposited - allocation.amount;
        
        // Disable yield on NFT
        betting_nft::set_yield_enabled(nft, false);
        betting_nft::set_yield_strategy_id(nft, option::none());
        
        // Emit withdrawal event
        event::emit(YieldWithdrawn {
            allocation_id: object::id(allocation),
            nft_id: object::id(nft),
            strategy_id: object::id(strategy),
            amount: allocation.amount,
            yield_amount: user_yield,
            user: tx_context::sender(ctx),
        });
        
        // Here we would actually withdraw from the DeFi protocol
        // For this demo, we'll just mint new coins
        
        // Transfer principal + yield to user
        let total_return = allocation.amount + user_yield;
        let return_coin = coin::mint_for_testing<SUI>(total_return, ctx);
        transfer::transfer(return_coin, tx_context::sender(ctx));
        
        // Transfer fee to treasury
        let fee_coin = coin::mint_for_testing<SUI>(fee_amount, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        
        // Delete the allocation
        let UserYieldAllocation { id, nft_id: _, strategy_id: _, amount: _, deposit_time: _, last_claimed_time: _, claimed_yield: _ } = allocation;
        object::delete(id);
    }
    
    // Harvest yield for a strategy (admin function)
    public entry fun harvest_strategy(
        strategy: &mut YieldStrategy,
        treasury: &mut YieldTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // In a real implementation, this would actually call the DeFi protocol
        // to harvest yield and reinvest or distribute it
        
        // For this demo, we'll just update the last harvest time
        let current_time = clock::timestamp_ms(clock);
        let time_diff_seconds = (current_time - strategy.last_harvest_time) / 1000;
        
        // Simulate yield harvesting
        let total_yield = (strategy.total_deposited * strategy.current_yield_rate * time_diff_seconds) / 31536000 / 10000;
        let treasury_fee = (total_yield * strategy.treasury_fee) / 10000;
        
        // Update strategy
        strategy.last_harvest_time = current_time;
        
        // Add fee to treasury
        let fee_coin = coin::mint_for_testing<SUI>(treasury_fee, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        
        // Emit harvest event
        event::emit(YieldHarvested {
            strategy_id: object::id(strategy),
            total_yield,
            treasury_fee,
        });
    }
    
    // Update yield rate for a strategy (admin function)
    public entry fun update_yield_rate(
        strategy: &mut YieldStrategy,
        new_rate: u64,
        ctx: &mut TxContext
    ) {
        // In a real implementation, verify caller is authorized
        
        // Update yield rate
        strategy.current_yield_rate = new_rate;
    }
    
    // Enable/disable a strategy (admin function)
    public entry fun set_strategy_active(
        strategy: &mut YieldStrategy,
        active: bool,
        ctx: &mut TxContext
    ) {
        // In a real implementation, verify caller is authorized
        
        // Update active status
        strategy.active = active;
    }
    
    // Withdraw treasury fees (admin function)
    public entry fun withdraw_treasury(
        treasury: &mut YieldTreasury,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        // In a real implementation, verify caller is authorized
        
        // Withdraw fees
        let fee_coin = coin::take(&mut treasury.balance, amount, ctx);
        transfer::transfer(fee_coin, recipient);
    }
    
    // Accessor functions
    public fun get_strategy_details(strategy: &YieldStrategy): (String, u64, u64, u8, bool) {
        (
            strategy.provider,
            strategy.total_deposited,
            strategy.current_yield_rate,
            strategy.risk_level,
            strategy.active
        )
    }
    
    public fun get_allocation_details(allocation: &UserYieldAllocation): (ID, ID, u64, u64, u64) {
        (
            allocation.nft_id,
            allocation.strategy_id,
            allocation.amount,
            allocation.last_claimed_time,
            allocation.claimed_yield
        )
    }
}
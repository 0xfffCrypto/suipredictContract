module sui_predict::amm {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui_predict::market::{Self, Market};
    use std::option::{Self, Option};
    
    // Error codes
    const EPoolAlreadyExists: u64 = 0;
    const EInsufficientLiquidity: u64 = 1;
    const EMarketNotOpen: u64 = 2;
    const ESlippageTooHigh: u64 = 3;
    const EInvalidBetAmount: u64 = 4;
    const EMarketNotResolved: u64 = 5;
    
    // AMM Pool structure
    struct Pool has key {
        id: UID,
        market_id: ID,
        yes_tokens: u64,
        no_tokens: u64,
        fee_percentage: u64, // in basis points (e.g., 30 = 0.3%)
        total_fees_collected: u64,
        k_value: u128, // Constant product value (x * y = k)
        locked_sui: Balance<SUI>,
    }
    
    // Bet structure
    struct Bet has key {
        id: UID,
        market_id: ID,
        position: bool, // true = YES, false = NO
        amount: u64,
        odds_at_purchase: u64, // in basis points (e.g., 5000 = 50%)
        potential_payout: u64,
        purchase_time: u64,
        owner: address,
    }
    
    // Events
    struct PoolCreated has copy, drop {
        pool_id: ID,
        market_id: ID,
        initial_liquidity: u64,
    }
    
    struct BetPlaced has copy, drop {
        bet_id: ID,
        market_id: ID,
        position: bool,
        amount: u64,
        odds: u64,
        potential_payout: u64,
        user: address,
    }
    
    struct BetSettled has copy, drop {
        bet_id: ID,
        market_id: ID,
        position: bool,
        amount: u64,
        payout: u64,
        user: address,
        win: bool,
    }
    
    // Create a new AMM pool for a prediction market
    public entry fun create_pool(
        market: &Market,
        initial_liquidity: Coin<SUI>,
        fee_percentage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify the market is open
        assert!(market::is_open(market), EMarketNotOpen);
        
        let market_id = object::id(market);
        let liquidity_amount = coin::value(&initial_liquidity);
        
        // Initial distribution - 50/50 split for YES/NO
        let half_liquidity = liquidity_amount / 2;
        
        // Create the pool
        let pool = Pool {
            id: object::new(ctx),
            market_id,
            yes_tokens: half_liquidity,
            no_tokens: half_liquidity,
            fee_percentage,
            total_fees_collected: 0,
            k_value: (half_liquidity as u128) * (half_liquidity as u128),
            locked_sui: coin::into_balance(initial_liquidity),
        };
        
        // Emit pool creation event
        event::emit(PoolCreated {
            pool_id: object::id(&pool),
            market_id,
            initial_liquidity: liquidity_amount,
        });
        
        // Share the pool object
        transfer::share_object(pool);
    }
    
    // Place a bet on the prediction market
    public entry fun place_bet(
        market: &Market,
        pool: &mut Pool,
        position: bool, // true = YES, false = NO
        bet_amount: Coin<SUI>,
        max_slippage: u64, // in basis points
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify the market is open
        assert!(market::is_open(market), EMarketNotOpen);
        
        // Verify the bet amount is within limits
        let amount = coin::value(&bet_amount);
        assert!(amount >= market::get_min_bet(market) && amount <= market::get_max_bet(market), EInvalidBetAmount);
        
        // Calculate current odds
        let (yes_odds, no_odds) = calculate_odds(pool);
        let odds = if position { yes_odds } else { no_odds };
        
        // Apply fees
        let treasury_fee = (amount * market::get_treasury_fee(market)) / 10000;
        let pool_fee = (amount * pool.fee_percentage) / 10000;
        let effective_amount = amount - treasury_fee - pool_fee;
        
        // Update pool state
        let (tokens_out, new_odds) = if position {
            // Betting on YES
            let tokens_out = calculate_output_amount(pool.no_tokens, pool.yes_tokens, effective_amount);
            pool.yes_tokens = pool.yes_tokens + effective_amount;
            pool.no_tokens = pool.no_tokens - tokens_out;
            (tokens_out, yes_odds)
        } else {
            // Betting on NO
            let tokens_out = calculate_output_amount(pool.yes_tokens, pool.no_tokens, effective_amount);
            pool.no_tokens = pool.no_tokens + effective_amount;
            pool.yes_tokens = pool.yes_tokens - tokens_out;
            (tokens_out, no_odds)
        };
        
        // Check slippage
        let new_yes_odds = (pool.no_tokens * 10000) / (pool.yes_tokens + pool.no_tokens);
        let new_no_odds = (pool.yes_tokens * 10000) / (pool.yes_tokens + pool.no_tokens);
        let actual_odds = if position { new_yes_odds } else { new_no_odds };
        let odds_diff = if odds > actual_odds { odds - actual_odds } else { actual_odds - odds };
        assert!(odds_diff <= max_slippage, ESlippageTooHigh);
        
        // Update k value
        pool.k_value = (pool.yes_tokens as u128) * (pool.no_tokens as u128);
        
        // Update fees collected
        pool.total_fees_collected = pool.total_fees_collected + pool_fee;
        
        // Add bet funds to the pool
        balance::join(&mut pool.locked_sui, coin::into_balance(bet_amount));
        
        // Calculate potential payout
        let potential_payout = amount * 10000 / odds;
        
        // Create bet object
        let bet = Bet {
            id: object::new(ctx),
            market_id: object::id(market),
            position,
            amount,
            odds_at_purchase: odds,
            potential_payout,
            purchase_time: clock::timestamp_ms(clock),
            owner: tx_context::sender(ctx),
        };
        
        // Emit bet event
        event::emit(BetPlaced {
            bet_id: object::id(&bet),
            market_id: object::id(market),
            position,
            amount,
            odds,
            potential_payout,
            user: tx_context::sender(ctx),
        });
        
        // Update market volume
        market::update_volume(market, amount);
        
        // Transfer bet object to the user
        transfer::transfer(bet, tx_context::sender(ctx));
    }
    
    // Settle a bet after market resolution
    public entry fun settle_bet(
        market: &Market,
        pool: &mut Pool,
        bet: Bet,
        ctx: &mut TxContext
    ) {
        // Ensure market is resolved
        assert!(market::is_resolved(market), EMarketNotResolved);
        
        // Get market result
        let result_option = market::get_result(market);
        assert!(option::is_some(&result_option), EMarketNotResolved);
        let result = option::extract(&mut result_option);
        
        // Calculate payout
        let win = bet.position == result;
        let payout = if win { bet.potential_payout } else { 0 };
        
        // Emit settlement event
        event::emit(BetSettled {
            bet_id: object::id(&bet),
            market_id: bet.market_id,
            position: bet.position,
            amount: bet.amount,
            payout,
            user: bet.owner,
            win,
        });
        
        // If the bet won, transfer payout to the user
        if win && payout > 0 {
            // Extract payout from pool
            let payout_coin = coin::take(&mut pool.locked_sui, payout, ctx);
            transfer::transfer(payout_coin, bet.owner);
        }
        
        // Destroy the bet object
        let Bet { id, market_id: _, position: _, amount: _, odds_at_purchase: _, potential_payout: _, purchase_time: _, owner: _ } = bet;
        object::delete(id);
    }
    
    // Helper function to calculate the output amount in AMM swap
    fun calculate_output_amount(in_reserve: u64, out_reserve: u64, in_amount: u64): u64 {
        // Using constant product formula: x * y = k
        // new_out_reserve = (in_reserve * out_reserve) / (in_reserve + in_amount)
        // tokens_out = out_reserve - new_out_reserve
        
        let product = (in_reserve as u128) * (out_reserve as u128);
        let new_in_reserve = (in_reserve as u128) + (in_amount as u128);
        let new_out_reserve = product / new_in_reserve;
        let tokens_out = (out_reserve as u128) - new_out_reserve;
        
        (tokens_out as u64)
    }
    
    // Calculate current odds for YES/NO positions
    public fun calculate_odds(pool: &Pool): (u64, u64) {
        let total = pool.yes_tokens + pool.no_tokens;
        if (total == 0) {
            return (5000, 5000) // 50/50 odds if no liquidity
        };
        
        let yes_odds = (pool.no_tokens * 10000) / total;
        let no_odds = (pool.yes_tokens * 10000) / total;
        
        (yes_odds, no_odds)
    }
    
    // Get the current pool state
    public fun get_pool_state(pool: &Pool): (u64, u64, u64, u64) {
        (pool.yes_tokens, pool.no_tokens, pool.fee_percentage, pool.total_fees_collected)
    }
}
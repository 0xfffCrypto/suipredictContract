module sui_predict::market {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;
    use sui::clock::{Self, Clock};
    use std::string::{Self, String};
    use std::option::{Self, Option};

    // Market status enum
    const MARKET_STATUS_OPEN: u8 = 0;
    const MARKET_STATUS_CLOSED: u8 = 1;
    const MARKET_STATUS_RESOLVED: u8 = 2;
    const MARKET_STATUS_DISPUTED: u8 = 3;

    // Error codes
    const EMarketAlreadyClosed: u64 = 0;
    const EMarketAlreadyResolved: u64 = 1;
    const EMarketNotClosed: u64 = 2;
    const EInvalidResolutionSource: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EBeforeResolutionTime: u64 = 5;

    // Market structure
    struct Market has key {
        id: UID,
        creator: address,
        description: String,
        resolution_time: u64,
        resolution_source: String,
        category: String,
        status: u8,
        result: Option<bool>,
        creation_time: u64,
        total_volume: u64,
        ai_generated: bool,
        min_bet: u64,
        max_bet: u64,
        treasury_fee: u64, // in basis points (e.g., 100 = 1%)
    }

    // Events
    struct MarketCreated has copy, drop {
        market_id: ID,
        creator: address,
        description: String,
        category: String,
        resolution_time: u64,
        ai_generated: bool,
    }

    struct MarketClosed has copy, drop {
        market_id: ID,
        close_time: u64,
    }

    struct MarketResolved has copy, drop {
        market_id: ID,
        result: bool,
        resolve_time: u64,
    }

    // Create a new prediction market
    public entry fun create_market(
        description: vector<u8>,
        resolution_source: vector<u8>,
        category: vector<u8>,
        resolution_time: u64,
        min_bet: u64,
        max_bet: u64,
        ai_generated: bool,
        treasury_fee: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Create the market object
        let market = Market {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            description: string::utf8(description),
            resolution_time,
            resolution_source: string::utf8(resolution_source),
            category: string::utf8(category),
            status: MARKET_STATUS_OPEN,
            result: option::none(),
            creation_time: current_time,
            total_volume: 0,
            ai_generated,
            min_bet,
            max_bet,
            treasury_fee,
        };
        
        let market_id = object::id(&market);
        
        // Emit event
        event::emit(MarketCreated {
            market_id,
            creator: tx_context::sender(ctx),
            description: string::utf8(description),
            category: string::utf8(category),
            resolution_time,
            ai_generated,
        });
        
        // Transfer market object to shared ownership
        transfer::share_object(market);
    }
    
    // Close the market (no more bets allowed)
    public entry fun close_market(
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Only creator can close the market
        assert!(market.creator == tx_context::sender(ctx), EUnauthorized);
        
        // Ensure market is not already closed or resolved
        assert!(market.status == MARKET_STATUS_OPEN, EMarketAlreadyClosed);
        
        // Close the market
        market.status = MARKET_STATUS_CLOSED;
        
        // Emit event
        event::emit(MarketClosed {
            market_id: object::id(market),
            close_time: clock::timestamp_ms(clock),
        });
    }
    
    // Resolve the market (determine outcome)
    public entry fun resolve_market(
        market: &mut Market,
        result: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Only creator can resolve the market
        assert!(market.creator == tx_context::sender(ctx), EUnauthorized);
        
        // Ensure market is closed but not resolved
        assert!(market.status == MARKET_STATUS_CLOSED, EMarketNotClosed);
        
        // Ensure resolution time has passed
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= market.resolution_time, EBeforeResolutionTime);
        
        // Set the result
        market.status = MARKET_STATUS_RESOLVED;
        market.result = option::some(result);
        
        // Emit event
        event::emit(MarketResolved {
            market_id: object::id(market),
            result,
            resolve_time: current_time,
        });
    }
    
    // Dispute the market resolution
    public entry fun dispute_market(
        market: &mut Market,
        ctx: &mut TxContext
    ) {
        // Only allow disputes for resolved markets
        assert!(market.status == MARKET_STATUS_RESOLVED, EMarketNotClosed);
        
        // Set status to disputed
        market.status = MARKET_STATUS_DISPUTED;
        
        // Dispute logic would be more complex in a real implementation
        // Might include staking, voting, or other governance mechanisms
    }
    
    // Accessor functions
    public fun is_open(market: &Market): bool {
        market.status == MARKET_STATUS_OPEN
    }
    
    public fun is_closed(market: &Market): bool {
        market.status == MARKET_STATUS_CLOSED
    }
    
    public fun is_resolved(market: &Market): bool {
        market.status == MARKET_STATUS_RESOLVED
    }
    
    public fun get_result(market: &Market): Option<bool> {
        market.result
    }
    
    public fun get_min_bet(market: &Market): u64 {
        market.min_bet
    }
    
    public fun get_max_bet(market: &Market): u64 {
        market.max_bet
    }
    
    public fun get_treasury_fee(market: &Market): u64 {
        market.treasury_fee
    }
    
    public fun get_total_volume(market: &Market): u64 {
        market.total_volume
    }
    
    // Internal function to update volume
    public(friend) fun update_volume(market: &mut Market, amount: u64) {
        market.total_volume = market.total_volume + amount;
    }
}
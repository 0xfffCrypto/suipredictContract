module sui_predict::betting_nft {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url::{Self, Url};
    use sui::event;
    use sui::package;
    use sui::display;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui_predict::market::{Self, Market};
    use sui_predict::amm::{Self, Bet, Pool};
    use std::string::{Self, String};
    use std::option::{Self, Option};
    
    // Error codes
    const EInvalidBetAmount: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EMarketNotOpen: u64 = 2;
    const EMarketNotResolved: u64 = 3;
    
    // One-time witness for the BettingNFT package
    struct BETTING_NFT has drop {}
    
    // BettingNFT structure
    struct BettingNFT has key, store {
        id: UID,
        market_id: ID,
        position: bool, // true = YES, false = NO
        amount: u64,
        odds_at_purchase: u64,
        potential_payout: u64,
        purchase_time: u64,
        bet_id: ID,
        metadata_uri: Url,
        yield_enabled: bool,
        yield_strategy_id: Option<ID>,
    }
    
    // Events
    struct NFTMinted has copy, drop {
        nft_id: ID,
        bet_id: ID,
        market_id: ID,
        position: bool,
        amount: u64,
        owner: address,
    }
    
    struct NFTTraded has copy, drop {
        nft_id: ID,
        from: address,
        to: address,
        price: u64,
    }
    
    // Initialize module
    fun init(witness: BETTING_NFT, ctx: &mut TxContext) {
        // Create and share Display object to specify NFT display properties
        let keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            string::utf8(b"image_url"),
            string::utf8(b"position"),
            string::utf8(b"amount"),
            string::utf8(b"odds"),
            string::utf8(b"potential_payout"),
            string::utf8(b"market_id"),
        ];
        
        let values = vector[
            string::utf8(b"SuiPredict Betting Position"),
            string::utf8(b"A betting position in the SuiPredict prediction market"),
            string::utf8(b"{metadata_uri}"),
            string::utf8(b"{position}"),
            string::utf8(b"{amount}"),
            string::utf8(b"{odds_at_purchase}"),
            string::utf8(b"{potential_payout}"),
            string::utf8(b"{market_id}"),
        ];
        
        // Register the Display
        let publisher = package::claim(witness, ctx);
        let display = display::new_with_fields<BettingNFT>(
            &publisher, keys, values, ctx
        );
        display::update_version(&mut display);
        
        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));
    }
    
    // Mint a new BettingNFT for a bet
    public fun mint_betting_nft(
        market: &Market,
        pool: &mut Pool,
        position: bool,
        bet_amount: Coin<SUI>,
        metadata_uri: vector<u8>,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): BettingNFT {
        // Verify the market is open
        assert!(market::is_open(market), EMarketNotOpen);
        
        // Verify the bet amount is within limits
        let amount = coin::value(&bet_amount);
        assert!(amount >= market::get_min_bet(market) && amount <= market::get_max_bet(market), EInvalidBetAmount);
        
        // Create the underlying bet
        let bet_id = object::new(ctx);
        
        // Create the NFT
        let nft = BettingNFT {
            id: object::new(ctx),
            market_id: object::id(market),
            position,
            amount,
            odds_at_purchase: 0, // Will be updated
            potential_payout: 0, // Will be updated
            purchase_time: clock::timestamp_ms(clock),
            bet_id: object::uid_to_inner(&bet_id),
            metadata_uri: url::new_unsafe_from_bytes(metadata_uri),
            yield_enabled: false,
            yield_strategy_id: option::none(),
        };
        
        // Calculate current odds
        let (yes_odds, no_odds) = amm::calculate_odds(pool);
        let odds = if position { yes_odds } else { no_odds };
        
        // Apply fees
        let treasury_fee = (amount * market::get_treasury_fee(market)) / 10000;
        let pool_fee = (amount * amm::get_pool_fee_percentage(pool)) / 10000;
        let effective_amount = amount - treasury_fee - pool_fee;
        
        // Update pool state
        let (tokens_out, new_odds) = if position {
            // Betting on YES
            let tokens_out = amm::calculate_output_amount(pool, false, effective_amount);
            amm::update_pool_balance(pool, true, effective_amount);
            amm::update_pool_balance(pool, false, -(tokens_out as i64));
            (tokens_out, yes_odds)
        } else {
            // Betting on NO
            let tokens_out = amm::calculate_output_amount(pool, true, effective_amount);
            amm::update_pool_balance(pool, false, effective_amount);
            amm::update_pool_balance(pool, true, -(tokens_out as i64));
            (tokens_out, no_odds)
        };
        
        // Check slippage
        let (new_yes_odds, new_no_odds) = amm::calculate_odds(pool);
        let actual_odds = if position { new_yes_odds } else { new_no_odds };
        let odds_diff = if odds > actual_odds { odds - actual_odds } else { actual_odds - odds };
        assert!(odds_diff <= max_slippage, amm::ESlippageTooHigh);
        
        // Update k value
        amm::update_k_value(pool);
        
        // Update fees collected
        amm::add_fees_collected(pool, pool_fee);
        
        // Add bet funds to the pool
        amm::add_to_locked_sui(pool, coin::into_balance(bet_amount));
        
        // Calculate potential payout
        let potential_payout = amount * 10000 / odds;
        
        // Update NFT fields
        let nft_mut = &mut nft;
        nft_mut.odds_at_purchase = odds;
        nft_mut.potential_payout = potential_payout;
        
        // Emit NFT minted event
        event::emit(NFTMinted {
            nft_id: object::id(nft_mut),
            bet_id: nft_mut.bet_id,
            market_id: nft_mut.market_id,
            position: nft_mut.position,
            amount: nft_mut.amount,
            owner: tx_context::sender(ctx),
        });
        
        // Update market volume
        market::update_volume(market, amount);
        
        nft
    }
    
    // Mint and transfer a new BettingNFT
    public entry fun mint_and_transfer_nft(
        market: &Market,
        pool: &mut Pool,
        position: bool,
        bet_amount: Coin<SUI>,
        metadata_uri: vector<u8>,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let nft = mint_betting_nft(
            market,
            pool,
            position,
            bet_amount,
            metadata_uri,
            max_slippage,
            clock,
            ctx
        );
        
        transfer::transfer(nft, tx_context::sender(ctx));
    }
    
    // Claim winnings after market resolution
    public entry fun claim_winnings(
        market: &Market,
        pool: &mut Pool,
        nft: BettingNFT,
        ctx: &mut TxContext
    ) {
        // Ensure market is resolved
        assert!(market::is_resolved(market), EMarketNotResolved);
        
        // Get market result
        let result_option = market::get_result(market);
        assert!(option::is_some(&result_option), EMarketNotResolved);
        let result = option::extract(&mut result_option);
        
        // Calculate payout
        let win = nft.position == result;
        let payout = if win { nft.potential_payout } else { 0 };
        
        // If the bet won, transfer payout to the user
        if win && payout > 0 {
            // Extract payout from pool
            let payout_coin = amm::extract_sui(pool, payout, ctx);
            transfer::transfer(payout_coin, tx_context::sender(ctx));
        }
        
        // Destroy the NFT object
        let BettingNFT { 
            id, 
            market_id: _, 
            position: _, 
            amount: _, 
            odds_at_purchase: _, 
            potential_payout: _, 
            purchase_time: _, 
            bet_id: _,
            metadata_uri: _,
            yield_enabled: _,
            yield_strategy_id: _
        } = nft;
        object::delete(id);
    }
    
    // List NFT for sale on marketplace
    // This would be implemented in the marketplace module
    
    // Enable yield generation for an NFT
    // This would be implemented in the yield module
    
    // Accessor functions
    public fun get_nft_details(nft: &BettingNFT): (ID, bool, u64, u64, u64, bool) {
        (
            nft.market_id,
            nft.position,
            nft.amount,
            nft.odds_at_purchase,
            nft.potential_payout,
            nft.yield_enabled
        )
    }
    
    public fun get_yield_strategy(nft: &BettingNFT): Option<ID> {
        nft.yield_strategy_id
    }
}
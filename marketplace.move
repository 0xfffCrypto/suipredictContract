module sui_predict::marketplace {
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
    use std::option::{Self, Option};
    
    // Error codes
    const EListingNotFound: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EInsufficientPayment: u64 = 2;
    const EListingExpired: u64 = 3;
    const EInvalidExpiration: u64 = 4;
    const EOfferNotFound: u64 = 5;
    const EOfferExpired: u64 = 6;
    
    // Listing structure
    struct Listing has key {
        id: UID,
        nft_id: ID,
        owner: address,
        price: u64,
        creation_time: u64,
        expiration_time: Option<u64>,
        marketplace_fee: u64, // in basis points (e.g., 250 = 2.5%)
    }
    
    // Offer structure
    struct Offer has key {
        id: UID,
        nft_id: ID,
        buyer: address,
        creation_time: u64,
        expiration_time: Option<u64>,
        payment: Balance<SUI>,
    }
    
    // Escrow for NFTs that are listed
    struct NFTEscrow has key {
        id: UID,
        listing_id: ID,
        nft: BettingNFT,
    }
    
    // Events
    struct ListingCreated has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
        price: u64,
        creation_time: u64,
        expiration_time: Option<u64>,
    }
    
    struct ListingCancelled has copy, drop {
        listing_id: ID,
        nft_id: ID,
        owner: address,
    }
    
    struct NFTSold has copy, drop {
        listing_id: ID,
        nft_id: ID,
        seller: address,
        buyer: address,
        price: u64,
        marketplace_fee: u64,
    }
    
    struct OfferCreated has copy, drop {
        offer_id: ID,
        nft_id: ID,
        buyer: address,
        amount: u64,
        creation_time: u64,
        expiration_time: Option<u64>,
    }
    
    struct OfferAccepted has copy, drop {
        offer_id: ID,
        nft_id: ID,
        seller: address,
        buyer: address,
        amount: u64,
    }
    
    struct OfferRejected has copy, drop {
        offer_id: ID,
        nft_id: ID,
        seller: address,
        buyer: address,
        amount: u64,
    }
    
    // Treasury to collect marketplace fees
    struct MarketplaceTreasury has key {
        id: UID,
        balance: Balance<SUI>,
    }
    
    // Initialize module with a treasury
    fun init(ctx: &mut TxContext) {
        transfer::share_object(
            MarketplaceTreasury {
                id: object::new(ctx),
                balance: balance::zero(),
            }
        );
    }
    
    // Create a new listing
    public entry fun create_listing(
        nft: BettingNFT,
        price: u64,
        marketplace_fee: u64,
        expiration_time: Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Validate expiration time if set
        if (option::is_some(&expiration_time)) {
            let exp_time = option::extract(&mut expiration_time);
            assert!(exp_time > current_time, EInvalidExpiration);
            expiration_time = option::some(exp_time);
        };
        
        // Create the listing
        let listing = Listing {
            id: object::new(ctx),
            nft_id: object::id(&nft),
            owner: tx_context::sender(ctx),
            price,
            creation_time: current_time,
            expiration_time,
            marketplace_fee,
        };
        
        // Create escrow to hold the NFT
        let escrow = NFTEscrow {
            id: object::new(ctx),
            listing_id: object::id(&listing),
            nft,
        };
        
        // Emit listing created event
        event::emit(ListingCreated {
            listing_id: object::id(&listing),
            nft_id: object::id(&nft),
            owner: tx_context::sender(ctx),
            price,
            creation_time: current_time,
            expiration_time,
        });
        
        // Share listing and escrow objects
        transfer::share_object(listing);
        transfer::share_object(escrow);
    }
    
    // Cancel a listing
    public entry fun cancel_listing(
        listing: &mut Listing,
        escrow: NFTEscrow,
        ctx: &mut TxContext
    ) {
        // Verify caller is the listing owner
        assert!(listing.owner == tx_context::sender(ctx), EUnauthorized);
        
        // Verify escrow matches the listing
        assert!(escrow.listing_id == object::id(listing), EListingNotFound);
        
        // Emit cancellation event
        event::emit(ListingCancelled {
            listing_id: object::id(listing),
            nft_id: listing.nft_id,
            owner: listing.owner,
        });
        
        // Return NFT to owner
        let NFTEscrow { id, listing_id: _, nft } = escrow;
        object::delete(id);
        transfer::transfer(nft, tx_context::sender(ctx));
    }
    
    // Buy an NFT
    public entry fun buy_nft(
        listing: &mut Listing,
        escrow: NFTEscrow,
        payment: Coin<SUI>,
        treasury: &mut MarketplaceTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify escrow matches the listing
        assert!(escrow.listing_id == object::id(listing), EListingNotFound);
        
        // Check if listing is expired
        let current_time = clock::timestamp_ms(clock);
        if (option::is_some(&listing.expiration_time)) {
            let exp_time = option::extract(&mut listing.expiration_time);
            assert!(current_time <= exp_time, EListingExpired);
            listing.expiration_time = option::some(exp_time);
        };
        
        // Verify payment amount
        let payment_amount = coin::value(&payment);
        assert!(payment_amount >= listing.price, EInsufficientPayment);
        
        // Calculate marketplace fee
        let fee_amount = (listing.price * listing.marketplace_fee) / 10000;
        let seller_amount = listing.price - fee_amount;
        
        // Process payment
        let fee_coin = coin::split(&mut payment, fee_amount, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        
        // Transfer remaining payment to seller
        transfer::transfer(payment, listing.owner);
        
        // Transfer NFT to buyer
        let NFTEscrow { id, listing_id: _, nft } = escrow;
        object::delete(id);
        
        // Emit sale event
        event::emit(NFTSold {
            listing_id: object::id(listing),
            nft_id: listing.nft_id,
            seller: listing.owner,
            buyer: tx_context::sender(ctx),
            price: listing.price,
            marketplace_fee: fee_amount,
        });
        
        transfer::transfer(nft, tx_context::sender(ctx));
    }
    
    // Make an offer for an NFT
    public entry fun make_offer(
        nft_id: ID,
        payment: Coin<SUI>,
        expiration_time: Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Validate expiration time if set
        if (option::is_some(&expiration_time)) {
            let exp_time = option::extract(&mut expiration_time);
            assert!(exp_time > current_time, EInvalidExpiration);
            expiration_time = option::some(exp_time);
        };
        
        // Create the offer
        let offer = Offer {
            id: object::new(ctx),
            nft_id,
            buyer: tx_context::sender(ctx),
            creation_time: current_time,
            expiration_time,
            payment: coin::into_balance(payment),
        };
        
        // Emit offer created event
        event::emit(OfferCreated {
            offer_id: object::id(&offer),
            nft_id,
            buyer: tx_context::sender(ctx),
            amount: balance::value(&offer.payment),
            creation_time: current_time,
            expiration_time,
        });
        
        // Share the offer object
        transfer::share_object(offer);
    }
    
    // Accept an offer
    public entry fun accept_offer(
        offer: &mut Offer,
        nft: BettingNFT,
        treasury: &mut MarketplaceTreasury,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify NFT matches the offer
        assert!(object::id(&nft) == offer.nft_id, EOfferNotFound);
        
        // Check if offer is expired
        let current_time = clock::timestamp_ms(clock);
        if (option::is_some(&offer.expiration_time)) {
            let exp_time = option::extract(&mut offer.expiration_time);
            assert!(current_time <= exp_time, EOfferExpired);
            offer.expiration_time = option::some(exp_time);
        };
        
        // Standard marketplace fee (could be made configurable)
        let marketplace_fee = 250; // 2.5%
        
        // Calculate fee
        let payment_amount = balance::value(&offer.payment);
        let fee_amount = (payment_amount * marketplace_fee) / 10000;
        let seller_amount = payment_amount - fee_amount;
        
        // Transfer fee to treasury
        let fee_coin = coin::take(&mut offer.payment, fee_amount, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
        
        // Transfer remaining payment to seller
        let seller_coin = coin::from_balance(balance::withdraw_all(&mut offer.payment), ctx);
        transfer::transfer(seller_coin, tx_context::sender(ctx));
        
        // Emit offer accepted event
        event::emit(OfferAccepted {
            offer_id: object::id(offer),
            nft_id: offer.nft_id,
            seller: tx_context::sender(ctx),
            buyer: offer.buyer,
            amount: payment_amount,
        });
        
        // Transfer NFT to buyer
        transfer::transfer(nft, offer.buyer);
    }
    
    // Reject an offer
    public entry fun reject_offer(
        offer: &mut Offer,
        nft: &BettingNFT,
        ctx: &mut TxContext
    ) {
        // Verify NFT matches the offer
        assert!(object::id(nft) == offer.nft_id, EOfferNotFound);
        
        // Return payment to buyer
        let payment_amount = balance::value(&offer.payment);
        let payment_coin = coin::from_balance(balance::withdraw_all(&mut offer.payment), ctx);
        transfer::transfer(payment_coin, offer.buyer);
        
        // Emit offer rejected event
        event::emit(OfferRejected {
            offer_id: object::id(offer),
            nft_id: offer.nft_id,
            seller: tx_context::sender(ctx),
            buyer: offer.buyer,
            amount: payment_amount,
        });
    }
    
    // Withdraw marketplace fees (admin only)
    // In a real implementation, this would have proper access control
    public entry fun withdraw_fees(
        treasury: &mut MarketplaceTreasury,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        // In a real implementation, verify caller is authorized
        
        // Withdraw fees
        let fee_coin = coin::take(&mut treasury.balance, amount, ctx);
        transfer::transfer(fee_coin, recipient);
    }
    
    // Get listing details
    public fun get_listing_details(listing: &Listing): (ID, address, u64, Option<u64>) {
        (listing.nft_id, listing.owner, listing.price, listing.expiration_time)
    }
    
    // Get offer details
    public fun get_offer_details(offer: &Offer): (ID, address, u64, Option<u64>) {
        (offer.nft_id, offer.buyer, balance::value(&offer.payment), offer.expiration_time)
    }
}
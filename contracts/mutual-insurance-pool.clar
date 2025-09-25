;; Mutual Insurance Pool Smart Contract
;; Manages insurance premiums, processes claims, and facilitates member voting on payouts

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-member (err u101))
(define-constant err-insufficient-funds (err u102))
(define-constant err-claim-not-found (err u103))
(define-constant err-voting-ended (err u104))
(define-constant err-already-voted (err u105))
(define-constant err-claim-not-approved (err u106))
(define-constant err-invalid-amount (err u107))
(define-constant err-member-exists (err u108))
(define-constant err-voting-active (err u109))
(define-constant err-minimum-stake (err u110))

;; Voting period (in blocks)
(define-constant voting-period u144) ;; ~24 hours assuming 10min blocks
(define-constant minimum-premium u100000) ;; 0.1 STX minimum
(define-constant minimum-stake-for-voting u50000) ;; 0.05 STX minimum stake to vote

;; Data Variables
(define-data-var total-pool-balance uint u0)
(define-data-var total-members uint u0)
(define-data-var claim-counter uint u0)
(define-data-var contract-active bool true)

;; Data Maps

;; Member information
(define-map members principal {
    premium-paid: uint,
    claims-submitted: uint,
    votes-cast: uint,
    reputation-score: uint,
    join-block: uint,
    active: bool
})

;; Claims data
(define-map claims uint {
    claimant: principal,
    amount: uint,
    description: (string-ascii 256),
    submission-block: uint,
    voting-end-block: uint,
    votes-for: uint,
    votes-against: uint,
    total-voting-power: uint,
    approved: bool,
    processed: bool,
    voters: (list 50 principal)
})

;; Vote tracking
(define-map votes {claim-id: uint, voter: principal} {
    vote: bool,
    voting-power: uint,
    block-height: uint
})

;; Premium payment history
(define-map premium-payments {member: principal, payment-id: uint} {
    amount: uint,
    block-height: uint,
    timestamp: uint
})

;; Helper Functions

;; Check if user is a member
(define-private (is-member (user principal))
    (is-some (map-get? members user))
)

;; Check if user is active member
(define-private (is-active-member (user principal))
    (match (map-get? members user)
        member-data (get active member-data)
        false
    )
)

;; Calculate voting power based on premium paid
(define-private (calculate-voting-power (member principal))
    (match (map-get? members member)
        member-data (/ (get premium-paid member-data) u10000)
        u0
    )
)

;; Check if claim exists
(define-private (claim-exists (claim-id uint))
    (is-some (map-get? claims claim-id))
)

;; Check if voting is active for a claim
(define-private (is-voting-active (claim-id uint))
    (match (map-get? claims claim-id)
        claim-data 
            (and 
                (<= stacks-block-height (get voting-end-block claim-data))
                (not (get processed claim-data))
            )
        false
    )
)

;; Public Functions

;; Join the insurance pool
(define-public (join-pool (premium uint))
    (let 
        ((member-exists (is-member tx-sender)))
        (asserts! (not member-exists) err-member-exists)
        (asserts! (>= premium minimum-premium) err-invalid-amount)
        (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
        (map-set members tx-sender {
            premium-paid: premium,
            claims-submitted: u0,
            votes-cast: u0,
            reputation-score: u100,
            join-block: stacks-block-height,
            active: true
        })
        (var-set total-pool-balance (+ (var-get total-pool-balance) premium))
        (var-set total-members (+ (var-get total-members) u1))
        (ok true)
    )
)

;; Pay additional premium to increase coverage
(define-public (pay-premium (amount uint))
    (let 
        ((member-data (unwrap! (map-get? members tx-sender) err-not-member)))
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (get active member-data) err-not-member)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set members tx-sender 
            (merge member-data {
                premium-paid: (+ (get premium-paid member-data) amount)
            })
        )
        (var-set total-pool-balance (+ (var-get total-pool-balance) amount))
        (ok true)
    )
)

;; Submit an insurance claim
(define-public (submit-claim (amount uint) (description (string-ascii 256)))
    (let 
        ((member-data (unwrap! (map-get? members tx-sender) err-not-member))
         (new-claim-id (+ (var-get claim-counter) u1)))
        (asserts! (get active member-data) err-not-member)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (<= amount (get premium-paid member-data)) err-insufficient-funds)
        
        ;; Create new claim
        (map-set claims new-claim-id {
            claimant: tx-sender,
            amount: amount,
            description: description,
            submission-block: stacks-block-height,
            voting-end-block: (+ stacks-block-height voting-period),
            votes-for: u0,
            votes-against: u0,
            total-voting-power: u0,
            approved: false,
            processed: false,
            voters: (list)
        })
        
        ;; Update member data
        (map-set members tx-sender 
            (merge member-data {
                claims-submitted: (+ (get claims-submitted member-data) u1)
            })
        )
        
        (var-set claim-counter new-claim-id)
        (ok new-claim-id)
    )
)

;; Vote on a claim
(define-public (vote-on-claim (claim-id uint) (approve bool))
    (let 
        ((member-data (unwrap! (map-get? members tx-sender) err-not-member))
         (claim-data (unwrap! (map-get? claims claim-id) err-claim-not-found))
         (voting-power (calculate-voting-power tx-sender))
         (has-voted (is-some (map-get? votes {claim-id: claim-id, voter: tx-sender}))))
        
        ;; Assertions
        (asserts! (get active member-data) err-not-member)
        (asserts! (>= (get premium-paid member-data) minimum-stake-for-voting) err-minimum-stake)
        (asserts! (is-voting-active claim-id) err-voting-ended)
        (asserts! (not has-voted) err-already-voted)
        (asserts! (not (is-eq tx-sender (get claimant claim-data))) err-not-member)
        
        ;; Record the vote
        (map-set votes {claim-id: claim-id, voter: tx-sender} {
            vote: approve,
            voting-power: voting-power,
            block-height: stacks-block-height
        })
        
        ;; Update claim data
        (map-set claims claim-id 
            (merge claim-data {
                votes-for: (if approve 
                    (+ (get votes-for claim-data) voting-power)
                    (get votes-for claim-data)
                ),
                votes-against: (if approve
                    (get votes-against claim-data)
                    (+ (get votes-against claim-data) voting-power)
                ),
                total-voting-power: (+ (get total-voting-power claim-data) voting-power),
                voters: (match (as-max-len? (append (get voters claim-data) tx-sender) u50)
                    new-list new-list
                    (get voters claim-data)
                )
            })
        )
        
        ;; Update member votes count
        (map-set members tx-sender 
            (merge member-data {
                votes-cast: (+ (get votes-cast member-data) u1),
                reputation-score: (+ (get reputation-score member-data) u1)
            })
        )
        
        (ok true)
    )
)

;; Process claim payout after voting ends
(define-public (process-payout (claim-id uint))
    (let 
        ((claim-data (unwrap! (map-get? claims claim-id) err-claim-not-found)))
        
        ;; Check if voting has ended
        (asserts! (> stacks-block-height (get voting-end-block claim-data)) err-voting-active)
        (asserts! (not (get processed claim-data)) err-claim-not-approved)
        
        ;; Determine if claim is approved (simple majority)
        (let 
            ((approved (> (get votes-for claim-data) (get votes-against claim-data)))
             (claimant (get claimant claim-data))
             (amount (get amount claim-data)))
            
            (if approved
                (begin
                    ;; Transfer funds to claimant
                    (try! (as-contract (stx-transfer? amount tx-sender claimant)))
                    (var-set total-pool-balance (- (var-get total-pool-balance) amount))
                    
                    ;; Update claim as processed and approved
                    (map-set claims claim-id 
                        (merge claim-data {
                            approved: true,
                            processed: true
                        })
                    )
                )
                ;; Just mark as processed but not approved
                (map-set claims claim-id 
                    (merge claim-data {
                        processed: true
                    })
                )
            )
            (ok approved)
        )
    )
)

;; Emergency function - deactivate member (only owner)
(define-public (deactivate-member (member principal))
    (let 
        ((member-data (unwrap! (map-get? members member) err-not-member)))
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set members member 
            (merge member-data {active: false})
        )
        (ok true)
    )
)

;; Read-Only Functions

;; Get total pool balance
(define-read-only (get-pool-balance)
    (var-get total-pool-balance)
)

;; Get total number of members
(define-read-only (get-total-members)
    (var-get total-members)
)

;; Get member information
(define-read-only (get-member-info (member principal))
    (map-get? members member)
)

;; Get claim details
(define-read-only (get-claim-details (claim-id uint))
    (map-get? claims claim-id)
)

;; Get voting status for a claim
(define-read-only (get-voting-status (claim-id uint))
    (match (map-get? claims claim-id)
        claim-data (ok {
            votes-for: (get votes-for claim-data),
            votes-against: (get votes-against claim-data),
            total-voting-power: (get total-voting-power claim-data),
            voting-ends: (get voting-end-block claim-data),
            is-active: (is-voting-active claim-id)
        })
        err-claim-not-found
    )
)

;; Get user's vote on a claim
(define-read-only (get-user-vote (claim-id uint) (voter principal))
    (map-get? votes {claim-id: claim-id, voter: voter})
)

;; Check if contract is active
(define-read-only (is-contract-active)
    (var-get contract-active)
)

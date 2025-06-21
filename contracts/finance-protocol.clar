;; Invoice Financing Protocol
;; Complete system with integrated credit scoring for immediate deployment

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-INVOICE-NOT-FOUND (err u404))
(define-constant ERR-INVALID-AMOUNT (err u400))
(define-constant ERR-INVOICE-ALREADY-FINANCED (err u409))
(define-constant ERR-INVOICE-EXPIRED (err u410))
(define-constant ERR-INSUFFICIENT-FUNDS (err u402))
(define-constant ERR-PAYMENT-FAILED (err u500))
(define-constant ERR-CREDIT-SCORE-TOO-LOW (err u403))
(define-constant ERR-INVOICE-NOT-DUE (err u425))

;; Financing parameters
(define-constant MAX-FINANCING-RATIO u90) ;; 90% max financing
(define-constant MIN-CREDIT-SCORE u500)   ;; Minimum credit score required
(define-constant COLLECTION-FEE-RATE u5)  ;; 5% collection fee
(define-constant PLATFORM-FEE-RATE u2)    ;; 2% platform fee

;; Credit scoring constants
(define-constant DEFAULT-CREDIT-SCORE u650)
(define-constant MAX-CREDIT-SCORE u850)

;; Data structures
(define-map invoices
  { invoice-id: uint }
  {
    seller: principal,
    buyer: principal,
    amount: uint,
    due-date: uint,
    created-at: uint,
    status: (string-ascii 20),
    financing-amount: uint,
    interest-rate: uint,
    financed-at: (optional uint),
    collected-at: (optional uint)
  }
)

(define-map user-stats
  { user: principal }
  {
    total-invoices: uint,
    total-financed: uint,
    successful-collections: uint,
    failed-collections: uint,
    total-payments: uint,
    successful-payments: uint,
    credit-score: uint,
    last-activity: uint
  }
)

(define-map financing-pool
  { provider: principal }
  {
    total-provided: uint,
    available-funds: uint,
    interest-earned: uint,
    joined-at: uint
  }
)

;; Sequence counters
(define-data-var invoice-counter uint u0)
(define-data-var total-pool-funds uint u0)

;; Contract state
(define-data-var contract-active bool true)
(define-data-var total-platform-fees uint u0)

;; Read-only functions
(define-read-only (get-invoice (invoice-id uint))
  (map-get? invoices { invoice-id: invoice-id })
)

(define-read-only (get-user-stats (user principal))
  (default-to
    {
      total-invoices: u0,
      total-financed: u0,
      successful-collections: u0,
      failed-collections: u0,
      total-payments: u0,
      successful-payments: u0,
      credit-score: DEFAULT-CREDIT-SCORE,
      last-activity: u0
    }
    (map-get? user-stats { user: user })
  )
)

(define-read-only (get-credit-score (user principal))
  (get credit-score (get-user-stats user))
)

(define-read-only (calculate-financing-terms (invoice-amount uint) (credit-score uint))
  (let (
    (risk-multiplier (if (>= credit-score u800) u100
                    (if (>= credit-score u700) u125
                    (if (>= credit-score u600) u150
                    u200))))
    (base-rate u500) ;; 5% base annual rate
    (annual-rate (/ (* base-rate risk-multiplier) u100))
  )
    (ok {
      max-financing: (/ (* invoice-amount MAX-FINANCING-RATIO) u100),
      interest-rate: annual-rate,
      platform-fee: (/ (* invoice-amount PLATFORM-FEE-RATE) u100)
    })
  )
)

(define-read-only (is-invoice-overdue (invoice-id uint))
  (match (get-invoice invoice-id)
    invoice-data (> stacks-block-height (get due-date invoice-data))
    false
  )
)

(define-read-only (calculate-updated-credit-score (current-score uint) (successful uint) (total uint))
  (let (
    (success-rate (if (> total u0) (/ (* successful u100) total) u100))
    (base-adjustment (if (>= success-rate u95) 20
                     (if (>= success-rate u90) 10
                     (if (>= success-rate u80) 5
                     (if (>= success-rate u70) 0
                     (if (>= success-rate u60) (- 10)
                     (- 20)))))))
    (new-score (+ current-score (to-uint base-adjustment)))
  )
    (if (> new-score MAX-CREDIT-SCORE) MAX-CREDIT-SCORE
    (if (< new-score u300) u300
    new-score))
  )
)

;; Public functions
(define-public (create-invoice (buyer principal) (amount uint) (due-date uint))
  (let (
    (invoice-id (+ (var-get invoice-counter) u1))
    (current-height stacks-block-height)
  )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> due-date current-height) ERR-INVOICE-EXPIRED)

    (map-set invoices
      { invoice-id: invoice-id }
      {
        seller: tx-sender,
        buyer: buyer,
        amount: amount,
        due-date: due-date,
        created-at: current-height,
        status: "pending",
        financing-amount: u0,
        interest-rate: u0,
        financed-at: none,
        collected-at: none
      }
    )

    (var-set invoice-counter invoice-id)

    ;; Update user stats
    (let ((current-stats (get-user-stats tx-sender)))
      (map-set user-stats
        { user: tx-sender }
        (merge current-stats {
          total-invoices: (+ (get total-invoices current-stats) u1),
          last-activity: current-height
        })
      )
    )

    (ok invoice-id)
  )
)

(define-public (finance-invoice (invoice-id uint))
  (let (
    (invoice-data (unwrap! (get-invoice invoice-id) ERR-INVOICE-NOT-FOUND))
    (seller (get seller invoice-data))
    (invoice-amount (get amount invoice-data))
    (current-height stacks-block-height)
  )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status invoice-data) "pending") ERR-INVOICE-ALREADY-FINANCED)
    (asserts! (< current-height (get due-date invoice-data)) ERR-INVOICE-EXPIRED)

    ;; Get credit score and calculate terms
    (let (
      (credit-score (get-credit-score seller))
      (financing-terms (unwrap! (calculate-financing-terms invoice-amount credit-score) ERR-CREDIT-SCORE-TOO-LOW))
      (financing-amount (get max-financing financing-terms))
      (platform-fee (get platform-fee financing-terms))
      (net-amount (- financing-amount platform-fee))
    )
      (asserts! (>= credit-score MIN-CREDIT-SCORE) ERR-CREDIT-SCORE-TOO-LOW)
      (asserts! (>= (var-get total-pool-funds) financing-amount) ERR-INSUFFICIENT-FUNDS)

      ;; Transfer funds to seller
      (try! (as-contract (stx-transfer? net-amount tx-sender seller)))

      ;; Update pool funds
      (var-set total-pool-funds (- (var-get total-pool-funds) financing-amount))

      ;; Update invoice status
      (map-set invoices
        { invoice-id: invoice-id }
        (merge invoice-data {
          status: "financed",
          financing-amount: financing-amount,
          interest-rate: (get interest-rate financing-terms),
          financed-at: (some current-height)
        })
      )

      ;; Update platform fees
      (var-set total-platform-fees (+ (var-get total-platform-fees) platform-fee))

      ;; Update user stats
      (let ((current-stats (get-user-stats seller)))
        (map-set user-stats
          { user: seller }
          (merge current-stats {
            total-financed: (+ (get total-financed current-stats) financing-amount),
            last-activity: current-height
          })
        )
      )

      (ok net-amount)
    )
  )
)

(define-public (collect-payment (invoice-id uint))
  (let (
    (invoice-data (unwrap! (get-invoice invoice-id) ERR-INVOICE-NOT-FOUND))
    (buyer (get buyer invoice-data))
    (seller (get seller invoice-data))
    (total-amount (get amount invoice-data))
    (financing-amount (get financing-amount invoice-data))
    (current-height stacks-block-height)
  )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status invoice-data) "financed") ERR-INVOICE-NOT-FOUND)
    (asserts! (or (is-eq tx-sender buyer)
                  (>= current-height (get due-date invoice-data))) ERR-NOT-AUTHORIZED)

    ;; Calculate interest and fees
    (let (
      (days-elapsed (- current-height (unwrap! (get financed-at invoice-data) ERR-INVOICE-NOT-FOUND)))
      (interest (/ (* financing-amount (get interest-rate invoice-data) days-elapsed) (* u365 u10000)))
      (collection-fee (if (> current-height (get due-date invoice-data))
                        (/ (* total-amount COLLECTION-FEE-RATE) u100)
                        u0))
      (total-due (+ financing-amount interest collection-fee))
    )
      ;; Process payment from buyer
      (try! (stx-transfer? total-due buyer (as-contract tx-sender)))

      ;; Return funds to pool
      (var-set total-pool-funds (+ (var-get total-pool-funds) financing-amount interest))

      ;; Update invoice status
      (map-set invoices
        { invoice-id: invoice-id }
        (merge invoice-data {
          status: "collected",
          collected-at: (some current-height)
        })
      )

      ;; Update user stats and credit score
      (let ((current-stats (get-user-stats seller)))
        (let (
          (new-successful (+ (get successful-payments current-stats) u1))
          (new-total (+ (get total-payments current-stats) u1))
          (new-credit-score (calculate-updated-credit-score
                            (get credit-score current-stats)
                            new-successful
                            new-total))
        )
          (map-set user-stats
            { user: seller }
            (merge current-stats {
              successful-collections: (+ (get successful-collections current-stats) u1),
              successful-payments: new-successful,
              total-payments: new-total,
              credit-score: new-credit-score,
              last-activity: current-height
            })
          )
        )
      )

      (ok total-due)
    )
  )
)

(define-public (mark-default (invoice-id uint))
  (let (
    (invoice-data (unwrap! (get-invoice invoice-id) ERR-INVOICE-NOT-FOUND))
    (seller (get seller invoice-data))
    (current-height stacks-block-height)
  )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (is-eq tx-sender (get seller invoice-data))) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status invoice-data) "financed") ERR-INVOICE-NOT-FOUND)
    (asserts! (> current-height (+ (get due-date invoice-data) u1440)) ERR-INVOICE-NOT-DUE) ;; 10 days overdue

    ;; Update invoice status
    (map-set invoices
      { invoice-id: invoice-id }
      (merge invoice-data {
        status: "defaulted",
        collected-at: (some current-height)
      })
    )

    ;; Update user stats and penalize credit score
    (let ((current-stats (get-user-stats seller)))
      (let (
        (new-total (+ (get total-payments current-stats) u1))
        (new-credit-score (calculate-updated-credit-score
                          (get credit-score current-stats)
                          (get successful-payments current-stats)
                          new-total))
        (penalized-score (if (> new-credit-score u50) (- new-credit-score u50) u300))
      )
        (map-set user-stats
          { user: seller }
          (merge current-stats {
            failed-collections: (+ (get failed-collections current-stats) u1),
            total-payments: new-total,
            credit-score: penalized-score,
            last-activity: current-height
          })
        )
      )
    )

    (ok true)
  )
)

(define-public (add-liquidity (amount uint))
  (let ((current-height stacks-block-height))
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)

    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

    ;; Update pool funds
    (var-set total-pool-funds (+ (var-get total-pool-funds) amount))

    ;; Track provider contribution
    (let ((current-pool (default-to
                         { total-provided: u0, available-funds: u0, interest-earned: u0, joined-at: current-height }
                         (map-get? financing-pool { provider: tx-sender }))))
      (map-set financing-pool
        { provider: tx-sender }
        (merge current-pool {
          total-provided: (+ (get total-provided current-pool) amount),
          available-funds: (+ (get available-funds current-pool) amount)
        })
      )
    )

    (ok amount)
  )
)

(define-public (withdraw-liquidity (amount uint))
  (let (
    (provider-pool (unwrap! (map-get? financing-pool { provider: tx-sender }) ERR-NOT-AUTHORIZED))
    (available (get available-funds provider-pool))
  )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount available) ERR-INSUFFICIENT-FUNDS)
    (asserts! (<= amount (var-get total-pool-funds)) ERR-INSUFFICIENT-FUNDS)

    ;; Transfer funds back to provider
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))

    ;; Update pool tracking
    (var-set total-pool-funds (- (var-get total-pool-funds) amount))
    (map-set financing-pool
      { provider: tx-sender }
      (merge provider-pool {
        available-funds: (- available amount)
      })
    )

    (ok amount)
  )
)

;; Admin functions
(define-public (toggle-contract-active)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-active (not (var-get contract-active)))
    (ok (var-get contract-active))
  )
)

(define-public (withdraw-platform-fees)
  (let ((total-fees (var-get total-platform-fees)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> total-fees u0) ERR-INVALID-AMOUNT)

    (try! (as-contract (stx-transfer? total-fees tx-sender CONTRACT-OWNER)))
    (var-set total-platform-fees u0)
    (ok total-fees)
  )
)

(define-public (manual-credit-adjustment (user principal) (new-score uint))
  (let ((current-stats (get-user-stats user)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (>= new-score u300) ERR-INVALID-AMOUNT)
    (asserts! (<= new-score MAX-CREDIT-SCORE) ERR-INVALID-AMOUNT)

    (map-set user-stats
      { user: user }
      (merge current-stats {
        credit-score: new-score,
        last-activity: stacks-block-height
      })
    )

    (ok new-score)
  )
)

;; Emergency functions
(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-active false)
    (ok true)
  )
)

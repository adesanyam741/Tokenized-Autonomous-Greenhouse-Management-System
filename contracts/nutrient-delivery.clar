;; Nutrient Delivery Contract
;; Manages automated plant feeding systems

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-unauthorized (err u201))
(define-constant err-invalid-amount (err u202))
(define-constant err-system-paused (err u203))
(define-constant err-insufficient-supply (err u204))

;; Data Variables
(define-data-var is-paused bool false)
(define-data-var delivery-counter uint u0)
(define-data-var schedule-counter uint u0)

;; Nutrient Types
(define-map nutrient-supplies
    (string-ascii 20)
    {
        current-level: uint,
        min-threshold: uint,
        max-capacity: uint,
        cost-per-unit: uint
    }
)

(define-map operators principal bool)

(define-map delivery-records
    uint
    {
        nutrient-type: (string-ascii 20),
        amount-delivered: uint,
        target-zone: uint,
        timestamp: uint,
        operator: principal,
        delivery-status: (string-ascii 20)
    }
)

(define-map delivery-schedules
    uint
    {
        nutrient-type: (string-ascii 20),
        zone-id: uint,
        frequency-hours: uint,
        amount-per-delivery: uint,
        next-delivery: uint,
        is-active: bool,
        created-by: principal
    }
)

(define-map zone-nutrient-levels
    { zone-id: uint, nutrient-type: (string-ascii 20) }
    {
        current-level: uint,
        last-updated: uint,
        optimal-range-min: uint,
        optimal-range-max: uint
    }
)

;; Authorization Functions
(define-read-only (is-owner (user principal))
    (is-eq user contract-owner)
)

(define-read-only (is-operator (user principal))
    (default-to false (map-get? operators user))
)

(define-read-only (is-authorized (user principal))
    (or (is-owner user) (is-operator user))
)

;; Admin Functions
(define-public (add-operator (operator principal))
    (begin
        (asserts! (is-owner tx-sender) err-owner-only)
        (ok (map-set operators operator true))
    )
)

(define-public (remove-operator (operator principal))
    (begin
        (asserts! (is-owner tx-sender) err-owner-only)
        (ok (map-delete operators operator))
    )
)

(define-public (pause-system)
    (begin
        (asserts! (is-owner tx-sender) err-owner-only)
        (ok (var-set is-paused true))
    )
)

(define-public (unpause-system)
    (begin
        (asserts! (is-owner tx-sender) err-owner-only)
        (ok (var-set is-paused false))
    )
)

;; Nutrient Supply Management
(define-public (initialize-nutrient (nutrient-type (string-ascii 20)) (initial-level uint) (min-threshold uint) (max-capacity uint) (cost-per-unit uint))
    (begin
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (<= min-threshold max-capacity) err-invalid-amount)
        (asserts! (<= initial-level max-capacity) err-invalid-amount)

        (ok (map-set nutrient-supplies nutrient-type
            {
                current-level: initial-level,
                min-threshold: min-threshold,
                max-capacity: max-capacity,
                cost-per-unit: cost-per-unit
            }
        ))
    )
)

(define-public (refill-nutrient-supply (nutrient-type (string-ascii 20)) (amount uint))
    (let
        (
            (current-supply (unwrap! (map-get? nutrient-supplies nutrient-type) err-invalid-amount))
            (new-level (+ (get current-level current-supply) amount))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (<= new-level (get max-capacity current-supply)) err-invalid-amount)

        (ok (map-set nutrient-supplies nutrient-type
            (merge current-supply { current-level: new-level })
        ))
    )
)

;; Zone Management
(define-public (set-zone-nutrient-parameters (zone-id uint) (nutrient-type (string-ascii 20)) (optimal-min uint) (optimal-max uint))
    (begin
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (< optimal-min optimal-max) err-invalid-amount)

        (ok (map-set zone-nutrient-levels { zone-id: zone-id, nutrient-type: nutrient-type }
            {
                current-level: u0,
                last-updated: block-height,
                optimal-range-min: optimal-min,
                optimal-range-max: optimal-max
            }
        ))
    )
)

;; Delivery Functions
(define-public (deliver-nutrients (nutrient-type (string-ascii 20)) (amount uint) (zone-id uint))
    (let
        (
            (supply-info (unwrap! (map-get? nutrient-supplies nutrient-type) err-invalid-amount))
            (delivery-id (+ (var-get delivery-counter) u1))
            (zone-key { zone-id: zone-id, nutrient-type: nutrient-type })
            (zone-info (default-to
                { current-level: u0, last-updated: u0, optimal-range-min: u0, optimal-range-max: u100 }
                (map-get? zone-nutrient-levels zone-key)
            ))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (>= (get current-level supply-info) amount) err-insufficient-supply)

        ;; Update supply levels
        (map-set nutrient-supplies nutrient-type
            (merge supply-info { current-level: (- (get current-level supply-info) amount) })
        )

        ;; Update zone levels
        (map-set zone-nutrient-levels zone-key
            (merge zone-info {
                current-level: (+ (get current-level zone-info) amount),
                last-updated: block-height
            })
        )

        ;; Record delivery
        (map-set delivery-records delivery-id
            {
                nutrient-type: nutrient-type,
                amount-delivered: amount,
                target-zone: zone-id,
                timestamp: block-height,
                operator: tx-sender,
                delivery-status: "completed"
            }
        )

        (var-set delivery-counter delivery-id)
        (ok delivery-id)
    )
)

;; Automated Scheduling
(define-public (create-delivery-schedule (nutrient-type (string-ascii 20)) (zone-id uint) (frequency-hours uint) (amount-per-delivery uint))
    (let
        (
            (schedule-id (+ (var-get schedule-counter) u1))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (> frequency-hours u0) err-invalid-amount)
        (asserts! (> amount-per-delivery u0) err-invalid-amount)

        (map-set delivery-schedules schedule-id
            {
                nutrient-type: nutrient-type,
                zone-id: zone-id,
                frequency-hours: frequency-hours,
                amount-per-delivery: amount-per-delivery,
                next-delivery: (+ block-height frequency-hours),
                is-active: true,
                created-by: tx-sender
            }
        )

        (var-set schedule-counter schedule-id)
        (ok schedule-id)
    )
)

(define-public (execute-scheduled-delivery (schedule-id uint))
    (let
        (
            (schedule-info (unwrap! (map-get? delivery-schedules schedule-id) err-invalid-amount))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (not (var-get is-paused)) err-system-paused)
        (asserts! (get is-active schedule-info) err-invalid-amount)
        (asserts! (>= block-height (get next-delivery schedule-info)) err-invalid-amount)

        ;; Execute delivery
        (try! (deliver-nutrients
            (get nutrient-type schedule-info)
            (get amount-per-delivery schedule-info)
            (get zone-id schedule-info)
        ))

        ;; Update next delivery time
        (map-set delivery-schedules schedule-id
            (merge schedule-info {
                next-delivery: (+ block-height (get frequency-hours schedule-info))
            })
        )

        (ok true)
    )
)

(define-public (deactivate-schedule (schedule-id uint))
    (let
        (
            (schedule-info (unwrap! (map-get? delivery-schedules schedule-id) err-invalid-amount))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)
        (asserts! (or (is-owner tx-sender) (is-eq tx-sender (get created-by schedule-info))) err-unauthorized)

        (ok (map-set delivery-schedules schedule-id
            (merge schedule-info { is-active: false })
        ))
    )
)

;; Monitoring Functions
(define-public (check-nutrient-levels-for-zone (zone-id uint) (nutrient-type (string-ascii 20)))
    (let
        (
            (zone-key { zone-id: zone-id, nutrient-type: nutrient-type })
            (zone-info (unwrap! (map-get? zone-nutrient-levels zone-key) err-invalid-amount))
            (current-level (get current-level zone-info))
            (optimal-min (get optimal-range-min zone-info))
            (optimal-max (get optimal-range-max zone-info))
        )
        (asserts! (is-authorized tx-sender) err-unauthorized)

        (ok {
            zone-id: zone-id,
            nutrient-type: nutrient-type,
            current-level: current-level,
            status: (if (< current-level optimal-min)
                "low"
                (if (> current-level optimal-max)
                    "high"
                    "optimal"
                )
            ),
            recommendation: (if (< current-level optimal-min)
                (- optimal-min current-level)
                u0
            )
        })
    )
)

;; Read-only Functions
(define-read-only (get-nutrient-supply (nutrient-type (string-ascii 20)))
    (map-get? nutrient-supplies nutrient-type)
)

(define-read-only (get-delivery-record (delivery-id uint))
    (map-get? delivery-records delivery-id)
)

(define-read-only (get-delivery-schedule (schedule-id uint))
    (map-get? delivery-schedules schedule-id)
)

(define-read-only (get-zone-nutrient-status (zone-id uint) (nutrient-type (string-ascii 20)))
    (map-get? zone-nutrient-levels { zone-id: zone-id, nutrient-type: nutrient-type })
)

(define-read-only (get-system-status)
    {
        is-paused: (var-get is-paused),
        total-deliveries: (var-get delivery-counter),
        active-schedules: (var-get schedule-counter)
    }
)

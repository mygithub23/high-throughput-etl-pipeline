# Impact vs Effort Prioritization Matrix

## Visual Prioritization

```
HIGH IMPACT  │
            │  🔴1            🔴3
            │  Idempotency    Orphan Records
            │  [10 min]       [2 hrs]
            │                              🟠5
            │  🔴2                         IAM Wildcards  
IMPACT      │  Memory Limit   🔴4          [30 min]
            │  [30 min]       VPC Config
            │                 [6 hrs]      🟡7
            │                              BatchWrite
            │                              [4 hrs]
            │  🟢8            🟢9
            │  Remove DEBUG   DLQ Config   🟡10
LOW IMPACT  │  [15 min]       [1 hr]       Logging
            │                              [1 day]
            └─────────────────────────────────────────
              LOW EFFORT                  HIGH EFFORT
```

**Legend**:
- 🔴 Critical Priority (Do First)
- 🟠 High Priority (This Sprint)
- 🟡 Medium Priority (Next Sprint)  
- 🟢 Low Priority (Backlog)

---

## Detailed Prioritization Table

| Priority | ID | Finding | Impact | Effort | ROI Score | Phase |
|----------|----|---------| -------|--------|-----------|-------|
| **P0** | 1 | Add idempotency to track_file | Data Loss | 10 min | ⭐⭐⭐⭐⭐ | Phase 1 |
| **P0** | 2 | Add Limit to DynamoDB query | Outage | 30 min | ⭐⭐⭐⭐⭐ | Phase 1 |
| **P0** | 3 | Fix orphaned MANIFEST records | Data Loss | 2 hrs | ⭐⭐⭐⭐⭐ | Phase 1 |
| **P1** | 4 | Add VPC configuration | Compliance | 6 hrs | ⭐⭐⭐⭐ | Phase 2* |
| **P1** | 5 | Fix IAM wildcards | Security | 30 min | ⭐⭐⭐⭐ | Phase 1 |
| **P1** | 6 | Add Glue encryption | Compliance | 2 hrs | ⭐⭐⭐⭐ | Phase 1 |
| **P2** | 7 | BatchWriteItem optimization | Performance | 4 hrs | ⭐⭐⭐ | Phase 2 |
| **P2** | 8 | Remove DEBUG logging | Security | 15 min | ⭐⭐⭐⭐ | Phase 1 |
| **P2** | 9 | Add Dead Letter Queue | Recovery | 1 hr | ⭐⭐⭐ | Phase 1 |
| **P2** | 10 | Structured JSON logging | Observability | 1 day | ⭐⭐⭐ | Phase 2 |
| **P3** | 11 | GSI write-sharding | Scale 500K | 2 days | ⭐⭐⭐⭐⭐ | Phase 3 |
| **P3** | 12 | Glue Flex | Cost savings | 2 days | ⭐⭐⭐⭐ | Phase 3 |
| **P3** | 13 | EventBridge decoupling | Architecture | 3 days | ⭐⭐ | Phase 3 |

\* *VPC becomes P0 if InfoSec confirms private cloud requirement*

---

## ROI Calculation Methodology

**ROI Score** = (Impact × Urgency) / (Effort × Complexity)

Where:
- **Impact**: 1-5 (Data loss=5, Cost savings=3, Code quality=1)
- **Urgency**: 1-5 (Blocking production=5, Nice-to-have=1)
- **Effort**: Hours required
- **Complexity**: 1-3 (Simple=1, Medium=2, Complex=3)

---

## Quick Win Opportunities (High ROI, Low Effort)

### Top 5 Quick Wins

| Rank | Fix | Impact | Effort | Why It's a Win |
|------|-----|--------|--------|----------------|
| 1️⃣ | Add idempotency check | Prevents data loss | 10 min | Single line of code, massive risk reduction |
| 2️⃣ | Remove DEBUG logging | Stop data exposure | 15 min | Change one line + env var |
| 3️⃣ | Fix IAM wildcards | Security compliance | 30 min | Copy-paste ARN references |
| 4️⃣ | Add query Limit | Prevent OOM crash | 30 min | Add one parameter |
| 5️⃣ | Add alarm actions | Enable alerting | 30 min | Copy ARN to all alarms |

**Total Time**: **2 hours**  
**Total Risk Reduction**: **Prevents 4 critical issues**

---

## Strategic Investments (High Impact, High Effort)

### Worth the Investment

| Investment | Effort | Benefit | When to Do |
|------------|--------|---------|------------|
| **VPC Configuration** | 6 hrs | Private cloud compliance, network isolation | Phase 2 (if required) |
| **GSI Write-Sharding** | 2 days | Removes scale bottleneck, enables 500K/day | Phase 3 (before scaling) |
| **Glue Flex** | 2 days | $1,950/month savings (36% reduction) | Phase 3 (optimization) |
| **Structured Logging** | 1 day | CloudWatch Insights, faster debugging | Phase 2 (quality of life) |

---

## Deferred Items (Low ROI)

These can wait until Phase 3 or later:

| Item | Why Defer | Alternative |
|------|-----------|-------------|
| Circuit breaker pattern | System is stable without it | Monitor first, add if needed |
| TTL helper function | Code duplication is minor | Refactor during next feature work |
| Dynamic Spark partitions | AQE handles this already | Optimize only if bottleneck observed |
| Unused CloudWatch client | No functional impact | Remove during code cleanup sprint |

---

## Decision Tree: What to Do First?

```
START
  │
  ├─ Are you deploying to production this week?
  │  └─ YES → Do ALL Phase 1 (8 hours) IMMEDIATELY
  │  └─ NO  → Continue
  │
  ├─ Is VPC required for private cloud?
  │  └─ YES → VPC becomes Phase 1 (add 6 hours)
  │  └─ NO  → Continue with standard Phase 1
  │
  ├─ Do you need 100K files/day in next 30 days?
  │  └─ YES → Do Phase 1 + Phase 2 (2 weeks total)
  │  └─ NO  → Phase 1 only, schedule Phase 2 later
  │
  ├─ Do you need 500K files/day this quarter?
  │  └─ YES → Do ALL 3 phases (6 weeks total)
  │  └─ NO  → Defer Phase 3 to next quarter
  │
  └─ Is budget tight ($5K/month max)?
       └─ YES → MUST complete Phase 3 before scaling
       └─ NO  → Can scale first, optimize later
```

---

## Risk-Based Prioritization

### If You Can Only Fix ONE Thing

**Fix**: Add idempotency to track_file (10 minutes)

**Why**: Prevents duplicate file tracking on SQS retries = **prevents data loss**

**Code Fix**:
```python
# Line 566 in lambda_manifest_builder.py
table.put_item(
    Item=item,
    ConditionExpression='attribute_not_exists(file_key)'  # ADD THIS LINE
)
```

### If You Can Only Fix THREE Things (1 Hour)

1. **Idempotency** (10 min) - prevents data loss
2. **Memory limit** (30 min) - prevents OOM crash
3. **Remove DEBUG** (15 min) - stops data exposure

**Total Time**: 55 minutes  
**Risk Coverage**: 75% of critical issues resolved

---

## Effort Estimation Details

### Phase 1: Critical Fixes (8 hours total)

| Task # | Description | Complexity | Estimated Time | Risk Buffer | Total |
|--------|-------------|------------|----------------|-------------|-------|
| 1 | Add ConditionExpression | Low | 5 min | 5 min | 10 min |
| 2 | Add LOG_LEVEL env var | Low | 3 min | 2 min | 5 min |
| 3 | Update Python logging | Low | 20 min | 10 min | 30 min |
| 4 | Add Limit to query | Low | 20 min | 10 min | 30 min |
| 5 | Add alarm actions | Low | 20 min | 10 min | 30 min |
| 6 | Add DLQ config | Medium | 45 min | 15 min | 1 hr |
| 7 | Reorder SF start | Medium | 1.5 hrs | 30 min | 2 hrs |
| 8 | Add COMPRESSION_TYPE | Low | 3 min | 2 min | 5 min |
| 9 | Glue security config | Medium | 1.5 hrs | 30 min | 2 hrs |
| 10 | Fix IAM wildcards (×2) | Low | 15 min | 5 min | 20 min |
| | **SUBTOTAL** | | **5.5 hrs** | **2.5 hrs** | **~8 hrs** |

### Phase 2: Scale Preparation (40-48 hours)

| Task # | Description | Complexity | Estimated Time | Risk Buffer | Total |
|--------|-------------|------------|----------------|-------------|-------|
| 1 | VPC for Lambda | High | 3 hrs | 1 hr | 4 hrs |
| 2 | VPC for Glue | High | 4 hrs | 2 hrs | 6 hrs |
| 3 | KMS encryption | Medium | 1 hr | 30 min | 1.5 hrs |
| 4 | Structured logging | High | 6 hrs | 2 hrs | 8 hrs |
| 5 | X-Ray tracing | Medium | 2 hrs | 1 hr | 3 hrs |
| 6 | BatchWriteItem | Medium | 3 hrs | 1 hr | 4 hrs |
| 7 | Exponential backoff | Low | 1.5 hrs | 30 min | 2 hrs |
| 8 | Saga pattern | High | 6 hrs | 2 hrs | 8 hrs |
| 9 | Orphan recovery job | Medium | 3 hrs | 1 hr | 4 hrs |
| 10 | Enable all env alarms | Low | 1 hr | 30 min | 1.5 hrs |
| | **SUBTOTAL** | | **31 hrs** | **11.5 hrs** | **~42 hrs** |

### Phase 3: Optimization (120-160 hours)

| Task # | Description | Complexity | Estimated Time | Risk Buffer | Total |
|--------|-------------|------------|----------------|-------------|-------|
| 1 | EventBridge migration | High | 18 hrs | 6 hrs | 24 hrs |
| 2 | GSI write-sharding | Very High | 12 hrs | 4 hrs | 16 hrs |
| 3 | Circuit breaker | High | 18 hrs | 6 hrs | 24 hrs |
| 4 | X-Ray distributed tracing | Medium | 6 hrs | 2 hrs | 8 hrs |
| 5 | DynamoDB Streams eval | Very High | 30 hrs | 10 hrs | 40 hrs |
| 6 | Glue Flex implementation | Medium | 12 hrs | 4 hrs | 16 hrs |
| 7 | Dynamic partition calc | Low | 2 hrs | 1 hr | 3 hrs |
| | **SUBTOTAL** | | **98 hrs** | **33 hrs** | **~131 hrs** |

**Estimation Methodology**: Based on industry averages + 25-30% risk buffer

---

## Resource Allocation Recommendations

### Phase 1 (1 Week)
- **Team Size**: 1 senior developer
- **Duration**: 1 day (8 hours)
- **Dependencies**: None
- **Parallel Work**: Can fix multiple items simultaneously

### Phase 2 (4 Weeks)
- **Team Size**: 1-2 developers (1 senior + 1 mid-level)
- **Duration**: 2 weeks with 2 developers OR 4 weeks with 1 developer
- **Dependencies**: InfoSec approval for VPC configs
- **Critical Path**: VPC configuration (if required)

### Phase 3 (3 Months)
- **Team Size**: 2 developers + 1 architect (part-time)
- **Duration**: 4-6 weeks calendar time
- **Dependencies**: Phase 2 completion, load testing environment
- **Critical Path**: GSI write-sharding design + implementation

---

## Success Metrics

### Phase 1 Success Criteria
- ✅ Zero idempotency failures in CloudWatch logs
- ✅ Lambda memory usage < 50% of allocated
- ✅ No DEBUG-level logs in production
- ✅ DLQ remains empty (no Lambda failures)
- ✅ IAM policy security scan passes
- ✅ Glue encryption enabled in AWS console

### Phase 2 Success Criteria
- ✅ All resources in VPC (verified by network diagram)
- ✅ X-Ray traces show end-to-end workflow
- ✅ Structured logs queryable in CloudWatch Insights
- ✅ Saga pattern tested with intentional Glue failure
- ✅ Orphan recovery job finds and fixes test orphans
- ✅ File update latency < 100ms (BatchWriteItem)

### Phase 3 Success Criteria
- ✅ DynamoDB GSI throttling = 0 at 500K files/day load test
- ✅ Monthly cost < $3,500 at 500K files/day
- ✅ EventBridge DLQ tested with failed invocations
- ✅ Circuit breaker triggers during simulated outage
- ✅ Glue Flex jobs complete within SLA (15 min)

---

## Stakeholder Communication Plan

### Weekly Status Report Template

```
## ETL Pipeline Improvements - Week [X]

### This Week's Progress
- ✅ Completed: [List items]
- 🔄 In Progress: [List items]
- ⏸️ Blocked: [List items + blockers]

### Next Week's Plan
- [ ] [Task 1]
- [ ] [Task 2]

### Metrics
- Risk Reduction: [X]% of critical issues resolved
- Budget Status: On track / [X]% over|under
- Timeline: On schedule / [X] days ahead|behind

### Decisions Needed
- [List any decisions needed from stakeholders]

### Risks & Mitigation
- Risk: [Description]
  Mitigation: [Plan]
```

---

## Parallel Work Opportunities

Items that CAN be worked on simultaneously:

### Phase 1 Parallel Track A (4 hours)
- Fix idempotency
- Add memory limit
- Remove DEBUG logging
- Fix IAM wildcards

### Phase 1 Parallel Track B (4 hours)
- Add DLQ
- Add Glue encryption
- Reorder SF start
- Add alarm actions

**Benefit**: Complete Phase 1 in **4 hours** with 2 developers instead of 8 hours with 1

### Phase 2 Parallel Tracks
- **Track A**: VPC + security (Lambda dev)
- **Track B**: Observability (Glue dev)
- **Track C**: Performance (Python optimization)

**Benefit**: Complete Phase 2 in **2 weeks** instead of 4

---

*Use this matrix to justify prioritization decisions to stakeholders and optimize team allocation.*

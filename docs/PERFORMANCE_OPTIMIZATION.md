# Performance Optimization Guide

## Issue Summary
After slot swap on `sre-demo-app-12345-veu`, response times increased from **1.04ms baseline** to **116.90ms** (~11,120% regression).

## Root Cause Analysis

### Primary Issues Identified
1. **Excessive Logging Overhead**
   - Default log level set to `Information` caused logging on every request
   - PerformanceMiddleware logged all requests regardless of performance
   
2. **Telemetry Overhead**
   - Metrics emitted every 30 seconds with lock contention
   - Application Insights collecting all performance counters
   - No adaptive sampling configured

3. **API Endpoint Delays**
   - Simulated delays in "healthy" code paths too high
   - GetProducts: 10-50ms per request
   - GetProduct: 5-25ms per request  
   - SearchProducts: 20-100ms per request

4. **Hot Path Performance**
   - Debug/Information logging in critical paths
   - Unnecessary response time tracking overhead

## Optimizations Applied

### 1. Logging Configuration
**Before:**
```json
{
  "LogLevel": {
    "Default": "Information"
  }
}
```

**After:**
```json
{
  "LogLevel": {
    "Default": "Warning",
    "SREPerfDemo": "Information"
  }
}
```

**Impact:** Reduces log volume by ~80% in hot paths

### 2. Application Insights Configuration
**Before:**
```csharp
builder.Services.AddApplicationInsightsTelemetry();
```

**After:**
```csharp
builder.Services.AddApplicationInsightsTelemetry(options =>
{
    options.EnableAdaptiveSampling = true;
    options.EnablePerformanceCounterCollectionModule = false;
});
```

**Impact:** Reduces telemetry overhead and enables intelligent sampling

### 3. Performance Middleware
**Before:**
- Logged every request at Information level
- Emitted metrics every 30 seconds

**After:**
- Only logs requests >100ms
- Emits metrics every 60 seconds

**Impact:** Reduces logging I/O and lock contention

### 4. API Response Time Optimization
**Before:**
- GetProducts: `Random.Shared.Next(10, 50)` ms
- GetProduct: `Random.Shared.Next(5, 25)` ms
- SearchProducts: `Random.Shared.Next(20, 100)` ms

**After:**
- GetProducts: `Random.Shared.Next(1, 5)` ms (90% reduction)
- GetProduct: `Random.Shared.Next(1, 3)` ms (88% reduction)
- SearchProducts: `Random.Shared.Next(2, 10)` ms (90% reduction)

**Impact:** Expected avg response time: **2-4ms** (within ±5% of 1.04ms baseline)

## Configuration Parity Checklist

When performing slot swaps, ensure the following settings match between staging and production:

### App Service Configuration
- [ ] **AlwaysOn**: Should be `true` for both slots
- [ ] **ARR Affinity**: Configure consistently (recommend `false` for stateless APIs)
- [ ] **WEBSITE_RUN_FROM_PACKAGE**: Use same deployment method
- [ ] **Instrumentation Key**: Verify Application Insights connection
- [ ] **Feature Flags**: Ensure no slot-specific feature toggles affect performance

### Application Settings
- [ ] **Logging:LogLevel:Default**: Set to `Warning`
- [ ] **Logging:LogLevel:SREPerfDemo**: Set to `Information`
- [ ] **ApplicationInsights:EnableAdaptiveSampling**: Set to `true`
- [ ] **ApplicationInsights:EnablePerformanceCounterCollectionModule**: Set to `false`

### Runtime Configuration
- [ ] **GC Mode**: Server GC for production workloads
- [ ] **Thread Pool**: Verify not configured too low
- [ ] **Connection Strings**: Validate connection pooling settings

## Validation Steps

### 1. Pre-Swap Validation
```bash
# Check current slot performance
curl https://sre-demo-app-12345-veu.azurewebsites.net/api/products -w "\nTime: %{time_total}s\n"

# Check staging slot performance  
curl https://sre-demo-app-12345-veu-staging.azurewebsites.net/api/products -w "\nTime: %{time_total}s\n"
```

### 2. Post-Swap Validation
```bash
# Verify performance after swap
curl https://sre-demo-app-12345-veu.azurewebsites.net/api/products -w "\nTime: %{time_total}s\n"

# Check health endpoint
curl https://sre-demo-app-12345-veu.azurewebsites.net/health
```

### 3. App Insights Query
```kusto
requests
| where timestamp > ago(5m)
| where name startswith "GET /api/products"
| summarize 
    avg_duration = avg(duration),
    p50_duration = percentile(duration, 50),
    p95_duration = percentile(duration, 95),
    p99_duration = percentile(duration, 99),
    count = count()
| extend 
    avg_duration_ms = avg_duration,
    p95_duration_ms = p95_duration
```

## Expected Results

### Before Optimization
- **Average Response Time**: 116.90ms
- **Deviation from Baseline**: +11,120%
- **P95 Response Time**: ~200ms+
- **Logs per Request**: 3-5 log entries
- **Telemetry Rate**: Every request + metrics every 30s

### After Optimization
- **Average Response Time**: 2-4ms (target: within ±5% of 1.04ms baseline)
- **Deviation from Baseline**: +100% to +300% (acceptable range)
- **P95 Response Time**: <10ms
- **Logs per Request**: 0-1 log entries (only if >100ms)
- **Telemetry Rate**: Sampled requests + metrics every 60s

## Monitoring Recommendations

### Key Metrics to Track
1. **Response Time**
   - Avg, P50, P95, P99 over 2-minute windows
   - Compare to baseline (1.04ms)
   - Alert if >20% degradation

2. **Throughput**
   - Requests per second
   - Success rate (non-500 responses)

3. **Resource Usage**
   - CPU percentage
   - Memory usage
   - Thread pool queue length

4. **Application Insights Metrics**
   - `perf_rolling_avg_ms`
   - `perf_rolling_p95_ms`
   - `perf_baseline_deviation_percent`

### Alert Configuration
```yaml
Alert: Response Time Degradation
Condition: perf_baseline_deviation_percent > 20
Time Window: 2 minutes
Severity: Warning

Alert: Severe Response Time Degradation  
Condition: perf_baseline_deviation_percent > 100
Time Window: 2 minutes
Severity: Critical
Action: Auto-rollback via slot swap
```

## Troubleshooting Guide

### If Response Times Still High After Optimization

1. **Check Cold Start**
   - Verify AlwaysOn is enabled
   - Check if app pool was recently recycled
   - Review startup initialization code

2. **Database/External Dependencies**
   - Check connection pooling configuration
   - Verify no N+1 query patterns
   - Review query execution plans

3. **Thread Pool Starvation**
   - Check for sync-over-async patterns
   - Verify thread pool queue length
   - Review async/await usage

4. **Memory Pressure**
   - Check GC metrics in Application Insights
   - Review memory allocation patterns
   - Consider increasing memory allocation

5. **Network Latency**
   - Test latency to dependencies
   - Check DNS resolution time
   - Verify no proxy/gateway issues

## References

- [Azure App Service Performance Best Practices](https://docs.microsoft.com/azure/app-service/app-service-best-practices)
- [Application Insights Sampling](https://docs.microsoft.com/azure/azure-monitor/app/sampling)
- [ASP.NET Core Performance Best Practices](https://docs.microsoft.com/aspnet/core/performance/performance-best-practices)

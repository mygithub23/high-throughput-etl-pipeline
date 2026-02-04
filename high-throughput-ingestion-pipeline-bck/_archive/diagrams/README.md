# Architecture Diagrams

This folder contains comprehensive architecture diagrams for the NDJSON to Parquet Pipeline.

## 🎨 Viewing the Diagrams

### Option 1: HTML Viewer (Recommended)
Open `index.html` in your browser for an interactive view of all diagrams with descriptions and metrics.

```bash
# Windows
start index.html

# Mac
open index.html

# Linux
xdg-open index.html
```

### Option 2: Direct SVG Viewing
All diagrams are in SVG format and can be opened directly in any modern browser or SVG viewer.

---

## 📊 Available Diagrams

### 1. Architecture Overview (`01-architecture-overview.svg`)
**What it shows:**
- Complete system architecture with all AWS services
- Data flow between components
- Monitoring and observability layer
- Production metrics and configuration

**Use this when:**
- Explaining the overall system to stakeholders
- Understanding component relationships
- Planning infrastructure changes

**Key Elements:**
- S3 buckets (Input, Manifest, Output, Quarantine)
- SQS event queue
- Lambda manifest builder
- DynamoDB file tracking
- AWS Glue batch jobs
- CloudWatch monitoring

---

### 2. Data Flow Diagram (`02-data-flow.svg`)
**What it shows:**
- 7 distinct processing stages
- Data transformations at each step
- Input/output data sizes
- Processing times

**Use this when:**
- Understanding data transformations
- Debugging data quality issues
- Optimizing processing performance

**Stages:**
1. Upload (NDJSON files to S3)
2. Event (S3 → SQS notification)
3. Tracking (Lambda validates and tracks)
4. Batching (Accumulate 100 files)
5. Manifest (Create JSON manifest)
6. Transform (Glue PySpark processing)
7. Output (Write Parquet files)

---

### 3. File Lifecycle Diagram (`03-file-lifecycle.svg`)
**What it shows:**
- 9 possible file states
- State transition triggers
- DynamoDB status field values
- Error paths and quarantine flow

**Use this when:**
- Tracking file processing status
- Understanding DynamoDB queries
- Debugging stuck files
- Implementing retry logic

**States:**
1. UPLOADED - File in S3
2. QUEUED - Event in SQS
3. VALIDATING - Size check in Lambda
4. PENDING - Waiting for batch
5. MANIFESTED - Included in manifest
6. PROCESSING - Glue job running
7. COMPLETED - Successfully processed
8. FAILED - Processing error
9. QUARANTINED - Invalid file

---

### 4. Sequence Diagram (`04-sequence-diagram.svg`)
**What it shows:**
- Chronological component interactions
- API calls and responses
- Timing and duration
- Async vs sync operations

**Use this when:**
- Understanding execution flow
- Debugging integration issues
- Estimating latency
- Planning API optimizations

**Key Interactions:**
- 13 sequential steps from upload to completion
- Lifelines for 8 components
- Message formats and payloads
- Timeline markers (0-15 minutes)

---

### 5. SQS & Manifest Flow (`05-sqs-manifest-flow.svg`)
**What it shows:**
- Detailed SQS message processing
- File-count batching logic
- Manifest JSON structure
- Configuration parameters

**Use this when:**
- Understanding batching strategy
- Configuring batch sizes
- Debugging manifest creation
- Optimizing Lambda logic

**Key Details:**
- SQS batch size: 10 messages
- File-count target: 100 files
- Manifest format: JSON with URIPrefixes
- Lambda decision logic

---

## 🔍 Diagram Format Details

### SVG Format Benefits
- ✅ Scalable without quality loss
- ✅ Small file size (~50-100 KB each)
- ✅ Viewable in all modern browsers
- ✅ Editable with tools like Inkscape, Adobe Illustrator
- ✅ Can be embedded in documentation
- ✅ Perfect for printing

### Color Coding

| Color | Service/Component |
|-------|-------------------|
| 🟢 Green | S3 buckets |
| 🟠 Orange | Lambda functions |
| 🟣 Purple | Glue jobs |
| 🔵 Blue | DynamoDB |
| 🔴 Pink/Red | SQS, CloudWatch, Errors |
| 🟡 Yellow | Decision points, Highlights |

---

## 📏 Dimensions

All diagrams are optimized for:
- **Viewing:** 1400-1600px width
- **Printing:** A3/Tabloid landscape
- **Presentations:** 16:9 aspect ratio compatible

---

## 🛠️ Editing Diagrams

If you need to modify the diagrams:

### Recommended Tools
1. **Inkscape** (Free, Open Source)
   - Download: https://inkscape.org/
   - Best for detailed SVG editing

2. **Figma** (Free tier available)
   - Import SVG and edit online
   - Great for collaboration

3. **Adobe Illustrator** (Paid)
   - Professional vector editing
   - Best for complex changes

### Quick Edits
You can also edit SVG files directly in a text editor since they're XML-based. Look for `<text>` elements to update labels and values.

---

## 📖 Use Cases

### For Development Team
- Understanding system architecture
- Debugging integration issues
- Planning new features
- Code reviews

### For Operations Team
- Monitoring production flow
- Incident response
- Capacity planning
- Cost optimization

### For Stakeholders
- System overview presentations
- Architecture review meetings
- Vendor discussions
- Audit documentation

### For Documentation
- README files (embed SVG)
- Wiki pages
- API documentation
- Runbooks

---

## 🎯 Key Metrics Shown

All diagrams include relevant metrics:

| Metric | Value |
|--------|-------|
| Daily Files | 338,000 files |
| File Size | 3.5-4.5 GB each |
| Daily Volume | 1.3 PB |
| Batch Size | 100 files/manifest |
| Concurrent Jobs | 30 |
| Workers/Job | 20 × G.2X |
| Processing Time | 9-15 hours/day |
| Compression Ratio | 5-7x |
| Output Size | 190-270 TB/day |
| Daily Cost | $2,500-$3,500 |

---

## 🔗 Related Documentation

- **[../environments/CONFIG-REFERENCE.md](../environments/CONFIG-REFERENCE.md)** - Detailed configuration
- **[../environments/BATCH-MODE-UPDATE-SUMMARY.md](../environments/BATCH-MODE-UPDATE-SUMMARY.md)** - Architecture summary
- **[../ARCHITECTURE-OPTIONS.md](../ARCHITECTURE-OPTIONS.md)** - Alternative designs
- **[../environments/DEPLOYMENT-CHECKLIST.md](../environments/DEPLOYMENT-CHECKLIST.md)** - Deployment guide

---

## 💡 Tips for Using Diagrams

### In Presentations
1. Use **01-architecture-overview.svg** for high-level context
2. Follow with **02-data-flow.svg** for technical details
3. Show **03-file-lifecycle.svg** for state management
4. Use **05-sqs-manifest-flow.svg** for batching strategy

### In Documentation
```markdown
![Architecture Overview](diagrams/01-architecture-overview.svg)
```

### For Debugging
1. **File stuck?** → Check **03-file-lifecycle.svg** for states
2. **Slow processing?** → Review **02-data-flow.svg** for bottlenecks
3. **Integration issue?** → Trace **04-sequence-diagram.svg**
4. **Batching problem?** → Analyze **05-sqs-manifest-flow.svg**

---

## 📝 Diagram Update History

| Date | Diagram | Change |
|------|---------|--------|
| 2025-12-24 | All | Initial creation with batch mode architecture |
| 2025-12-24 | 05 | Added file-count batching logic |
| 2025-12-24 | 03 | Updated with 9 states and DynamoDB status values |

---

## ✅ Diagram Checklist

When reviewing or updating diagrams, ensure:

- [ ] All metrics are current (338K files/day, etc.)
- [ ] Mode is shown as "glueetl" (batch), NOT "gluestreaming"
- [ ] Batch size is 100 files (file-count batching)
- [ ] Concurrent jobs is 30
- [ ] Workers are 20 × G.2X
- [ ] Compression ratio is 5-7x
- [ ] All S3 bucket names include account ID placeholder
- [ ] DynamoDB tables show correct status values
- [ ] Timeline/duration estimates are accurate

---

## 🎨 Diagram Conventions

### Arrows
- **Solid line** → Synchronous call/data flow
- **Dashed line** → Asynchronous event/notification
- **Thick blue** → Primary data flow
- **Thin gray** → Control flow

### Boxes
- **Rounded corners** → Services (S3, Lambda, Glue)
- **Sharp corners** → Data/Logic
- **Diamond** → Decision point
- **Circle** → Step number/state

### Text
- **Bold** → Component/service name
- **Regular** → Description
- **Monospace** → Code, metrics, config values

---

## 📞 Questions?

If you need clarification on any diagram:
1. Check the related documentation links above
2. Review the **index.html** file for interactive view
3. Refer to the specific diagram's section in this README

---

**All diagrams created:** December 24, 2025
**Format:** SVG (Scalable Vector Graphics)
**Total diagrams:** 5
**Total size:** ~300 KB (all diagrams combined)

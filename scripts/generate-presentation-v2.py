#!/usr/bin/env python3
"""
Generate PowerPoint presentation for Hub-and-Spoke EKS Architecture
Updated to reflect current progress and architecture decisions
"""

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.enum.text import PP_ALIGN
from pptx.dml.color import RGBColor

def create_presentation():
    prs = Presentation()
    prs.slide_width = Inches(10)
    prs.slide_height = Inches(7.5)

    # Define colors
    AWS_ORANGE = RGBColor(255, 153, 0)
    DARK_GRAY = RGBColor(35, 47, 62)
    LIGHT_GRAY = RGBColor(149, 165, 166)
    GREEN = RGBColor(39, 174, 96)
    RED = RGBColor(231, 76, 60)
    BLUE = RGBColor(52, 152, 219)
    YELLOW = RGBColor(241, 196, 15)

    # Slide 1: Title
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    title_box = slide.shapes.add_textbox(Inches(1), Inches(2.5), Inches(8), Inches(1))
    title_frame = title_box.text_frame
    title_frame.text = "Hub-and-Spoke EKS Architecture"
    title_para = title_frame.paragraphs[0]
    title_para.font.size = Pt(54)
    title_para.font.bold = True
    title_para.font.color.rgb = DARK_GRAY
    title_para.alignment = PP_ALIGN.CENTER

    subtitle_box = slide.shapes.add_textbox(Inches(1), Inches(3.5), Inches(8), Inches(0.5))
    subtitle_frame = subtitle_box.text_frame
    subtitle_frame.text = "Multi-Customer Kubernetes Platform"
    subtitle_para = subtitle_frame.paragraphs[0]
    subtitle_para.font.size = Pt(28)
    subtitle_para.font.color.rgb = LIGHT_GRAY
    subtitle_para.alignment = PP_ALIGN.CENTER

    date_box = slide.shapes.add_textbox(Inches(1), Inches(6.5), Inches(8), Inches(0.5))
    date_frame = date_box.text_frame
    date_frame.text = "June 2026 • AWS Access Account"
    date_para = date_frame.paragraphs[0]
    date_para.font.size = Pt(14)
    date_para.font.color.rgb = LIGHT_GRAY
    date_para.alignment = PP_ALIGN.CENTER

    # Slide 2: Architecture Overview
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Architecture: Hub-and-Spoke Model"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    arch_text = """┌──────────────────────────────────────┐
│   Hub Account (Shared Services)     │
│                                      │
│  • ECR Container Registry           │
│  • CloudWatch Logs (centralized)    │
│  • Amazon Managed Prometheus        │
│  • Optional: Shared tools cluster   │
└──────────┬───────────┬───────────────┘
           │           │
     ┌─────┴───┐   ┌───┴──────┐
     │         │   │          │
 ┌───▼────┐ ┌─▼──────┐ ┌─────▼──┐
 │Customer│ │Customer│ │Customer│
 │   1    │ │   2    │ │   3    │
 │  EKS   │ │  EKS   │ │  EKS   │
 │Cluster │ │Cluster │ │Cluster │
 └────────┘ └────────┘ └────────┘"""

    p = tf.paragraphs[0]
    p.text = arch_text
    p.font.size = Pt(14)
    p.font.name = 'Courier New'
    p.font.color.rgb = DARK_GRAY

    p = tf.add_paragraph()
    p.text = "\nKey Principle:"
    p.font.size = Pt(18)
    p.font.bold = True

    p = tf.add_paragraph()
    p.text = "Customers bring their OWN EKS clusters in their OWN AWS accounts"
    p.font.size = Pt(14)
    p.level = 1

    p = tf.add_paragraph()
    p.text = "Hub provides shared services: ECR, logging, monitoring"
    p.font.size = Pt(14)
    p.level = 1

    # Slide 3: What We've Built
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Current Progress - What's Working"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "Infrastructure (Spoke Cluster):"
    p.font.size = Pt(20)
    p.font.bold = True
    p.font.color.rgb = GREEN

    items = [
        "✅ EKS Cluster deployed with CloudFormation",
        "✅ Bottlerocket OS on nodes (immutable, minimal)",
        "✅ BRUPOP (Bottlerocket Update Operator) - auto-updates nodes",
        "✅ Node groups with taints for workload isolation",
        "✅ EBS CSI Driver with IAM permissions (fixed)",
        "✅ Pod Identity for secure AWS service access",
        "✅ RBAC with least-privilege roles"
    ]

    for item in items:
        p = tf.add_paragraph()
        p.text = item
        p.font.size = Pt(14)
        p.level = 1
        p.font.color.rgb = GREEN

    p = tf.add_paragraph()
    p.text = "\nApplication Layer:"
    p.font.size = Pt(20)
    p.font.bold = True
    p.font.color.rgb = GREEN

    app_items = [
        "✅ StatefulSets with EBS persistent volumes",
        "✅ Flask demo app with persistence tested",
        "✅ Data survives pod deletion (verified)",
        "✅ Encrypted GP3 volumes provisioning automatically"
    ]

    for item in app_items:
        p = tf.add_paragraph()
        p.text = item
        p.font.size = Pt(14)
        p.level = 1
        p.font.color.rgb = GREEN

    # Slide 4: Bottlerocket + BRUPOP
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Bottlerocket OS + BRUPOP"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "Why Bottlerocket?"
    p.font.size = Pt(20)
    p.font.bold = True

    reasons = [
        ("Immutable OS", "Can't SSH in and make changes → no drift"),
        ("Minimal Attack Surface", "Only what Kubernetes needs → more secure"),
        ("Purpose-Built", "Designed specifically for containers"),
        ("Auto-Updates", "BRUPOP handles rolling updates automatically")
    ]

    for title_text, detail in reasons:
        p = tf.add_paragraph()
        p.text = f"✅ {title_text}"
        p.font.size = Pt(15)
        p.font.bold = True
        p.level = 1

        p = tf.add_paragraph()
        p.text = detail
        p.font.size = Pt(13)
        p.font.italic = True
        p.level = 2
        p.font.color.rgb = LIGHT_GRAY

    p = tf.add_paragraph()
    p.text = "\nBRUPOP Status: ✅ Deployed and Running"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = GREEN

    p = tf.add_paragraph()
    p.text = "Automatically updates Bottlerocket nodes with zero-touch"
    p.font.size = Pt(14)
    p.level = 1

    # Slide 5: Demo - What I'll Show
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Demo - EBS Persistent Storage"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "What I'll Demonstrate:"
    p.font.size = Pt(20)
    p.font.bold = True

    demo_steps = [
        "1. Show running StatefulSet with 2 replicas",
        "2. Each pod has dedicated 5GB EBS volume",
        "3. Add data via REST API",
        "4. Delete a pod (simulate failure)",
        "5. Pod recreates automatically",
        "6. Data still intact - persistence works! ✅"
    ]

    for step in demo_steps:
        p = tf.add_paragraph()
        p.text = step
        p.font.size = Pt(16)
        p.level = 1
        if "✅" in step:
            p.font.color.rgb = GREEN
            p.font.bold = True

    p = tf.add_paragraph()
    p.text = "\nProves:"
    p.font.size = Pt(18)
    p.font.bold = True

    proofs = [
        "✓ Stateful workloads work (databases, etc.)",
        "✓ Data survives pod restarts",
        "✓ EBS CSI driver functioning correctly",
        "✓ Ready for production workloads"
    ]

    for proof in proofs:
        p = tf.add_paragraph()
        p.text = proof
        p.font.size = Pt(14)
        p.level = 1
        p.font.color.rgb = GREEN

    # Slide 6: Hub-Spoke Connection Pattern
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "How Customers Connect to Hub"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    connections = [
        ("1. Container Images (ECR)", [
            "Hub: Builds and pushes images to ECR",
            "Spoke: Pulls images from hub ECR",
            "No imagePullSecrets needed - IAM handles it",
            "Status: 🟡 Ready to implement"
        ]),
        ("2. Centralized Logging", [
            "Spoke: FluentBit sends logs to hub CloudWatch",
            "Hub: All logs in one place for troubleshooting",
            "Status: 🟡 Ready to implement"
        ]),
        ("3. Centralized Monitoring", [
            "Spoke: Prometheus sends metrics to hub AMP",
            "Hub: One Grafana dashboard for all customers",
            "Status: 🟡 Ready to implement"
        ])
    ]

    for conn_title, details in connections:
        p = tf.paragraphs[0] if conn_title == connections[0][0] else tf.add_paragraph()
        p.text = conn_title
        p.font.size = Pt(16)
        p.font.bold = True
        p.font.color.rgb = BLUE

        for detail in details:
            p = tf.add_paragraph()
            p.text = detail
            p.font.size = Pt(13)
            p.level = 1
            if "Status:" in detail:
                p.font.color.rgb = YELLOW
                p.font.bold = True

    # Slide 7: What's Complete vs In Progress
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Status Summary"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "✅ COMPLETE - Spoke Cluster Foundation"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = GREEN

    complete = [
        "EKS cluster infrastructure (CloudFormation)",
        "Bottlerocket nodes with BRUPOP",
        "EBS CSI driver + persistent volumes",
        "Pod Identity for AWS service access",
        "RBAC security model",
        "StatefulSet demo working"
    ]

    for item in complete:
        p = tf.add_paragraph()
        p.text = f"✓ {item}"
        p.font.size = Pt(13)
        p.level = 1

    p = tf.add_paragraph()
    p.text = "\n🟡 IN PROGRESS - Hub Infrastructure"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = YELLOW

    in_progress = [
        "Deploy hub account (ECR, CloudWatch, AMP)",
        "Configure ECR cross-account access",
        "Set up centralized logging pipeline",
        "Set up centralized monitoring pipeline"
    ]

    for item in in_progress:
        p = tf.add_paragraph()
        p.text = f"→ {item}"
        p.font.size = Pt(13)
        p.level = 1

    p = tf.add_paragraph()
    p.text = "\n⏳ NOT STARTED"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = LIGHT_GRAY

    not_started = [
        "Deploy second customer cluster (proof of multi-customer)",
        "Network connectivity (PrivateLink) - if needed"
    ]

    for item in not_started:
        p = tf.add_paragraph()
        p.text = f"  {item}"
        p.font.size = Pt(13)
        p.level = 1
        p.font.color.rgb = LIGHT_GRAY

    # Slide 8: Technical Wins
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Technical Achievements"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    wins = [
        ("Bottlerocket + BRUPOP Working", [
            "Automatic OS updates without manual intervention",
            "Minimal attack surface for security",
            "Immutable infrastructure - no configuration drift"
        ]),
        ("EBS CSI Driver Fixed", [
            "Required debugging IAM permissions",
            "Added inline policy to node role",
            "Now provisions encrypted GP3 volumes automatically"
        ]),
        ("StatefulSets Validated", [
            "Tested pod deletion and recreation",
            "Data persists across pod lifecycle",
            "Ready for databases and stateful apps"
        ]),
        ("Infrastructure as Code", [
            "CloudFormation templates for repeatability",
            "Deployment scripts for automation",
            "Can recreate entire cluster from code"
        ])
    ]

    for win_title, details in wins:
        p = tf.paragraphs[0] if win_title == wins[0][0] else tf.add_paragraph()
        p.text = f"✅ {win_title}"
        p.font.size = Pt(15)
        p.font.bold = True
        p.font.color.rgb = GREEN

        for detail in details:
            p = tf.add_paragraph()
            p.text = detail
            p.font.size = Pt(12)
            p.level = 1

    # Slide 9: Roadmap - Next 2-4 Weeks
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Roadmap - Phase 1 (Next 2-4 Weeks)"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "Priority 1: Complete Hub Account"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = BLUE

    hub_tasks = [
        "Deploy hub CloudFormation template",
        "Create ECR repositories with cross-account policies",
        "Set up CloudWatch log group for all customers",
        "Deploy Amazon Managed Prometheus workspace",
        "Test ECR pull from spoke cluster"
    ]

    for task in hub_tasks:
        p = tf.add_paragraph()
        p.text = f"→ {task}"
        p.font.size = Pt(13)
        p.level = 1

    p = tf.add_paragraph()
    p.text = "\nPriority 2: Connect Spoke to Hub"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = BLUE

    connect_tasks = [
        "Deploy application using hub ECR images",
        "Deploy FluentBit for centralized logging",
        "Deploy Prometheus for centralized monitoring",
        "Verify all connections working"
    ]

    for task in connect_tasks:
        p = tf.add_paragraph()
        p.text = f"→ {task}"
        p.font.size = Pt(13)
        p.level = 1

    p = tf.add_paragraph()
    p.text = "\nPriority 3: Second Customer"
    p.font.size = Pt(18)
    p.font.bold = True
    p.font.color.rgb = BLUE

    p = tf.add_paragraph()
    p.text = "Deploy second spoke cluster to prove multi-customer model"
    p.font.size = Pt(13)
    p.level = 1

    # Slide 10: Roadmap - Phase 2
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Roadmap - Phase 2 (1-3 Months)"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    phase2 = [
        ("Observability Enhancements", [
            "Deploy Grafana in hub for visualizations",
            "Set up alerting (CloudWatch Alarms)",
            "Configure dashboards for all customers"
        ]),
        ("Secrets Management", [
            "AWS Secrets Manager CSI Driver",
            "Test secret mounting and rotation",
            "Document pattern for customers"
        ]),
        ("Network Connectivity (If Needed)", [
            "PrivateLink for shared services",
            "Only if customers need network access to hub",
            "Most workloads won't need this"
        ]),
        ("Automation", [
            "Customer onboarding scripts",
            "Terraform modules for repeatability",
            "Self-service documentation"
        ])
    ]

    for category, items in phase2:
        p = tf.paragraphs[0] if category == phase2[0][0] else tf.add_paragraph()
        p.text = category
        p.font.size = Pt(15)
        p.font.bold = True
        p.font.color.rgb = BLUE

        for item in items:
            p = tf.add_paragraph()
            p.text = item
            p.font.size = Pt(12)
            p.level = 1

    # Slide 11: Key Decisions Needed
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Decisions Needed"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    decisions = [
        ("Decision 1: Hub Cluster",
         "Deploy EKS cluster in hub for Grafana/tools? Or run tools elsewhere?",
         "Timeline: This week",
         "Recommendation: Start without hub cluster (save $250/month)"),

        ("Decision 2: Customer Account IDs",
         "Which AWS account IDs need access to hub ECR?",
         "Timeline: Before hub deployment",
         "Required: At least one customer account ID"),

        ("Decision 3: Non-Prod vs Prod",
         "Deploy non-prod environment? Or start with prod?",
         "Timeline: Next sprint",
         "Recommendation: Start with one cluster, add non-prod later"),

        ("Decision 4: IAM Permission Expansion",
         "Approve expanded EKS Management role permissions?",
         "Timeline: ASAP - currently blocking operations",
         "Current: eks:*, Need: ec2:*, iam:*, cloudformation:*")
    ]

    for i, (dec_title, desc, timeline, rec) in enumerate(decisions):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text = dec_title
        p.font.size = Pt(14)
        p.font.bold = True
        if "Decision 4" in dec_title:
            p.font.color.rgb = RED
        else:
            p.font.color.rgb = DARK_GRAY

        p = tf.add_paragraph()
        p.text = desc
        p.font.size = Pt(12)
        p.level = 1

        p = tf.add_paragraph()
        p.text = f"⏰ {timeline}"
        p.font.size = Pt(11)
        p.font.italic = True
        p.level = 2
        p.font.color.rgb = LIGHT_GRAY

        p = tf.add_paragraph()
        p.text = f"💡 {rec}"
        p.font.size = Pt(11)
        p.level = 2
        if "blocking" in rec.lower():
            p.font.color.rgb = RED
            p.font.bold = True
        else:
            p.font.color.rgb = GREEN

    # Slide 12: Cost Estimate
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Cost Breakdown"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    p = tf.paragraphs[0]
    p.text = "Current Environment (1 Spoke Cluster):"
    p.font.size = Pt(18)
    p.font.bold = True

    current_costs = [
        ("EKS Control Plane", "$73/month"),
        ("EC2 Nodes (3x m5.xlarge)", "$350/month"),
        ("EBS Volumes (2x 5GB GP3)", "$1/month"),
        ("Data Transfer", "$30/month"),
        ("Total (current)", "$454/month")
    ]

    for item, cost in current_costs:
        p = tf.add_paragraph()
        if "Total" in item:
            p.text = f"\n{item:30} {cost}"
            p.font.bold = True
            p.font.size = Pt(14)
            p.font.color.rgb = GREEN
        else:
            p.text = f"{item:30} {cost}"
            p.font.size = Pt(12)
            p.font.name = 'Courier New'
        p.level = 1

    p = tf.add_paragraph()
    p.text = "\nFull Hub-and-Spoke (3 Customers):"
    p.font.size = Pt(18)
    p.font.bold = True

    full_costs = [
        ("Hub (no cluster)", "$50-100/month"),
        ("   ECR, CloudWatch, AMP only", ""),
        ("Customer 1 (current cluster)", "$454/month"),
        ("Customer 2 cluster", "$454/month"),
        ("Customer 3 cluster", "$454/month"),
        ("Total (3 customers)", "$1,500/month")
    ]

    for item, cost in full_costs:
        p = tf.add_paragraph()
        if "Total" in item:
            p.text = f"\n{item:35} {cost}"
            p.font.bold = True
            p.font.size = Pt(14)
            p.font.color.rgb = GREEN
        elif cost == "":
            p.text = item
            p.font.size = Pt(11)
            p.font.italic = True
            p.level = 2
            p.font.color.rgb = LIGHT_GRAY
        else:
            p.text = f"{item:35} {cost}"
            p.font.size = Pt(12)
            p.font.name = 'Courier New'
        p.level = 1

    # Slide 13: Risk & Mitigation
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Risks & Mitigation"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    risks = [
        ("IAM Permission Gaps", "Medium", "Expand EKS Management role (needed)"),
        ("Hub not deployed yet", "Medium", "Deploy this week (phase 1 priority)"),
        ("Single spoke cluster", "Low", "Proves concept, add more later"),
        ("No centralized logging yet", "High", "Deploy after hub complete"),
        ("No non-prod environment", "Medium", "Add after prod validated"),
    ]

    p = tf.paragraphs[0]
    p.text = "Risk                          Impact   Mitigation"
    p.font.size = Pt(12)
    p.font.name = 'Courier New'
    p.font.bold = True

    for risk, impact, mitigation in risks:
        p = tf.add_paragraph()
        p.text = f"{risk:30} {impact:8} {mitigation}"
        p.font.size = Pt(11)
        p.font.name = 'Courier New'
        p.level = 1

        if impact == "High":
            p.font.color.rgb = RED
        elif impact == "Medium":
            p.font.color.rgb = YELLOW

    # Slide 14: Success Metrics
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    title = slide.shapes.title
    title.text = "Success Metrics"

    content = slide.placeholders[1]
    tf = content.text_frame
    tf.clear()

    metrics = [
        ("Technical Metrics", [
            "Cluster uptime: 99.9% target",
            "Pod startup time: <30 seconds ✅ achieved",
            "PVC provisioning: <2 minutes ✅ achieved",
            "BRUPOP updates: Zero-touch ✅ working"
        ]),
        ("Phase 1 Goals (2-4 weeks)", [
            "Hub deployed and operational",
            "1 spoke pulling images from hub ECR",
            "Centralized logging functional",
            "Centralized monitoring functional"
        ]),
        ("Phase 2 Goals (1-3 months)", [
            "2+ spoke clusters connected",
            "Grafana dashboards for all customers",
            "Automated customer onboarding",
            "Secrets management validated"
        ])
    ]

    for category, items in metrics:
        p = tf.paragraphs[0] if category == metrics[0][0] else tf.add_paragraph()
        p.text = category
        p.font.size = Pt(16)
        p.font.bold = True
        p.font.color.rgb = BLUE

        for item in items:
            p = tf.add_paragraph()
            p.text = item
            p.font.size = Pt(13)
            p.level = 1
            if "✅" in item:
                p.font.color.rgb = GREEN

    # Slide 15: Q&A
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    qa_box = slide.shapes.add_textbox(Inches(1), Inches(2.5), Inches(8), Inches(2))
    qa_frame = qa_box.text_frame
    qa_frame.text = "Questions & Discussion"
    qa_para = qa_frame.paragraphs[0]
    qa_para.font.size = Pt(48)
    qa_para.font.bold = True
    qa_para.font.color.rgb = DARK_GRAY
    qa_para.alignment = PP_ALIGN.CENTER

    topics_box = slide.shapes.add_textbox(Inches(2), Inches(4.5), Inches(6), Inches(2))
    topics_frame = topics_box.text_frame
    topics_text = """Open Topics:
• Hub deployment timeline?
• Customer account IDs for ECR access?
• IAM permission approval?

Demo Ready:
• StatefulSet with persistent storage
• Bottlerocket + BRUPOP in action"""

    topics_frame.text = topics_text
    for para in topics_frame.paragraphs:
        para.font.size = Pt(16)
        para.alignment = PP_ALIGN.CENTER
        para.font.color.rgb = LIGHT_GRAY

    # Save presentation
    output_path = "/Users/manavkhanna/Documents/Projects/Kubernetes/Hub-Spoke-EKS-Architecture.pptx"
    prs.save(output_path)
    return output_path

if __name__ == "__main__":
    try:
        output = create_presentation()
        print(f"✅ PowerPoint created successfully: {output}")
    except Exception as e:
        print(f"❌ Error creating PowerPoint: {e}")
        import traceback
        traceback.print_exc()

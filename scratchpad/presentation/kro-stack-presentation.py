#!/usr/bin/env python3
"""
KRO Stack Stakeholder Presentation Generator
Generates a professional PDF presentation showcasing the GitHub-first approach
with KRO stack, Kyverno policy management, and Azure AD integration.
"""

from reportlab.lib.pagesizes import LETTER, landscape
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib.colors import HexColor, white, black
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, Image, ListFlowable, ListItem
)
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
from reportlab.pdfgen import canvas
from reportlab.lib import colors
import os

# Color palette
PRIMARY_BLUE = HexColor('#0066CC')
DARK_BLUE = HexColor('#003366')
LIGHT_BLUE = HexColor('#E6F2FF')
ACCENT_GREEN = HexColor('#28A745')
ACCENT_ORANGE = HexColor('#FD7E14')
GRAY = HexColor('#6C757D')
LIGHT_GRAY = HexColor('#F8F9FA')
DARK_GRAY = HexColor('#343A40')

class KROPresentationPDF:
    def __init__(self, filename):
        self.filename = filename
        self.width, self.height = landscape(LETTER)
        self.styles = getSampleStyleSheet()
        self._setup_styles()

    def _setup_styles(self):
        """Setup custom paragraph styles"""
        # Title style
        self.styles.add(ParagraphStyle(
            name='SlideTitle',
            parent=self.styles['Heading1'],
            fontSize=36,
            textColor=DARK_BLUE,
            alignment=TA_CENTER,
            spaceAfter=30,
            fontName='Helvetica-Bold'
        ))

        # Subtitle style
        self.styles.add(ParagraphStyle(
            name='SlideSubtitle',
            parent=self.styles['Normal'],
            fontSize=20,
            textColor=GRAY,
            alignment=TA_CENTER,
            spaceAfter=20
        ))

        # Body text
        self.styles.add(ParagraphStyle(
            name='SlideBody',
            parent=self.styles['Normal'],
            fontSize=16,
            textColor=DARK_GRAY,
            alignment=TA_LEFT,
            spaceAfter=12,
            leading=22
        ))

        # Bullet points
        self.styles.add(ParagraphStyle(
            name='BulletPoint',
            parent=self.styles['Normal'],
            fontSize=14,
            textColor=DARK_GRAY,
            leftIndent=20,
            spaceAfter=8,
            leading=20
        ))

        # Section header
        self.styles.add(ParagraphStyle(
            name='SectionHeader',
            parent=self.styles['Heading2'],
            fontSize=24,
            textColor=PRIMARY_BLUE,
            spaceBefore=20,
            spaceAfter=15,
            fontName='Helvetica-Bold'
        ))

        # Highlight box
        self.styles.add(ParagraphStyle(
            name='Highlight',
            parent=self.styles['Normal'],
            fontSize=14,
            textColor=DARK_BLUE,
            backColor=LIGHT_BLUE,
            borderPadding=10,
            spaceAfter=10
        ))

    def draw_header_footer(self, canvas, doc):
        """Draw consistent header/footer on each page"""
        canvas.saveState()

        # Header line
        canvas.setStrokeColor(PRIMARY_BLUE)
        canvas.setLineWidth(3)
        canvas.line(0.5*inch, self.height - 0.5*inch, self.width - 0.5*inch, self.height - 0.5*inch)

        # Footer
        canvas.setFillColor(GRAY)
        canvas.setFont('Helvetica', 10)
        canvas.drawString(0.5*inch, 0.4*inch, "UK8S KRO Stack - Stakeholder Presentation")
        canvas.drawRightString(self.width - 0.5*inch, 0.4*inch, f"Page {doc.page}")

        # Footer line
        canvas.setStrokeColor(LIGHT_GRAY)
        canvas.setLineWidth(1)
        canvas.line(0.5*inch, 0.6*inch, self.width - 0.5*inch, 0.6*inch)

        canvas.restoreState()

    def create_title_slide(self):
        """Create title slide content"""
        elements = []
        elements.append(Spacer(1, 1.5*inch))

        elements.append(Paragraph(
            "UK8S KRO Stack",
            self.styles['SlideTitle']
        ))

        elements.append(Paragraph(
            "GitHub-First Kubernetes Infrastructure with Kyverno Policy Management",
            self.styles['SlideSubtitle']
        ))

        elements.append(Spacer(1, 0.5*inch))

        # Key highlights table
        highlights = [
            ['Declarative Infrastructure', 'Policy-Driven Security', 'GitOps Automation'],
            ['KRO + Azure Service Operator', 'Kyverno Admission Control', 'Flux CD Continuous Delivery']
        ]

        t = Table(highlights, colWidths=[2.8*inch, 2.8*inch, 2.8*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), LIGHT_BLUE),
            ('TEXTCOLOR', (0, 0), (-1, 0), DARK_BLUE),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, -1), 12),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 15),
            ('TEXTCOLOR', (0, 1), (-1, 1), GRAY),
            ('FONTSIZE', (0, 1), (-1, 1), 10),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.8*inch))

        elements.append(Paragraph(
            "Azure Kubernetes Service | Management Groups | Azure AD Integration",
            ParagraphStyle(
                name='Footer',
                parent=self.styles['Normal'],
                fontSize=14,
                textColor=GRAY,
                alignment=TA_CENTER
            )
        ))

        elements.append(PageBreak())
        return elements

    def create_agenda_slide(self):
        """Create agenda slide"""
        elements = []
        elements.append(Paragraph("Agenda", self.styles['SlideTitle']))
        elements.append(Spacer(1, 0.3*inch))

        agenda_items = [
            ("1.", "Executive Summary", "Why GitHub-First Infrastructure?"),
            ("2.", "Architecture Overview", "Three-Layer KRO Stack Design"),
            ("3.", "GitOps Workflow", "Infrastructure as Code Pipeline"),
            ("4.", "Kyverno Policy Management", "Security & Compliance Governance"),
            ("5.", "Management Cluster Strategy", "Per Management Group Architecture"),
            ("6.", "Azure AD Integration", "Identity & Access Management"),
            ("7.", "Certification & Validation", "Automated Compliance Checks"),
            ("8.", "Benefits & Value", "Business Value Summary"),
        ]

        data = [[item[0], f"<b>{item[1]}</b><br/><font size='10' color='gray'>{item[2]}</font>"]
                for item in agenda_items]

        # Convert to proper paragraphs
        table_data = []
        for item in agenda_items:
            table_data.append([
                Paragraph(f"<b>{item[0]}</b>", self.styles['SlideBody']),
                Paragraph(f"<b>{item[1]}</b><br/><font size='10' color='gray'>{item[2]}</font>", self.styles['SlideBody'])
            ])

        t = Table(table_data, colWidths=[0.5*inch, 8*inch])
        t.setStyle(TableStyle([
            ('ALIGN', (0, 0), (0, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 8),
            ('TOPPADDING', (0, 0), (-1, -1), 8),
            ('LINEBELOW', (0, 0), (-1, -2), 0.5, LIGHT_GRAY),
        ]))
        elements.append(t)

        elements.append(PageBreak())
        return elements

    def create_executive_summary(self):
        """Create executive summary slide"""
        elements = []
        elements.append(Paragraph("Executive Summary", self.styles['SlideTitle']))
        elements.append(Paragraph("Why GitHub-First Infrastructure?", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Two column layout
        col_data = [
            [
                Paragraph("<b>Traditional Approach</b>", self.styles['SectionHeader']),
                Paragraph("<b>GitHub-First Approach</b>", self.styles['SectionHeader'])
            ],
            [
                Paragraph("""
                <font color='#DC3545'>✗</font> Manual cluster provisioning<br/>
                <font color='#DC3545'>✗</font> Configuration drift over time<br/>
                <font color='#DC3545'>✗</font> Inconsistent security policies<br/>
                <font color='#DC3545'>✗</font> No audit trail for changes<br/>
                <font color='#DC3545'>✗</font> Slow disaster recovery
                """, self.styles['BulletPoint']),
                Paragraph("""
                <font color='#28A745'>✓</font> Declarative cluster definitions<br/>
                <font color='#28A745'>✓</font> Git as single source of truth<br/>
                <font color='#28A745'>✓</font> Policy-as-Code enforcement<br/>
                <font color='#28A745'>✓</font> Complete audit history<br/>
                <font color='#28A745'>✓</font> Instant DR from Git state
                """, self.styles['BulletPoint'])
            ]
        ]

        t = Table(col_data, colWidths=[4.5*inch, 4.5*inch])
        t.setStyle(TableStyle([
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('RIGHTPADDING', (0, 0), (-1, -1), 15),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Key stat box
        stat_data = [
            ['50 UAMIs → 5 UAMIs', '10x Faster Recovery', '100% Policy Compliance'],
            ['Shared Identity Model', 'GitOps-Based DR', 'Automated Enforcement']
        ]

        t = Table(stat_data, colWidths=[3*inch, 3*inch, 3*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), PRIMARY_BLUE),
            ('TEXTCOLOR', (0, 0), (-1, 0), white),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, 0), 16),
            ('FONTSIZE', (0, 1), (-1, 1), 10),
            ('TEXTCOLOR', (0, 1), (-1, 1), GRAY),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 12),
            ('TOPPADDING', (0, 0), (-1, -1), 12),
            ('BOX', (0, 0), (-1, -1), 2, PRIMARY_BLUE),
        ]))
        elements.append(t)

        elements.append(PageBreak())
        return elements

    def create_architecture_slide(self):
        """Create architecture overview slide"""
        elements = []
        elements.append(Paragraph("Three-Layer Architecture", self.styles['SlideTitle']))
        elements.append(Paragraph("KRO Stack Design: Deploy Once, Share Everywhere", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Architecture diagram as table
        arch_data = [
            [Paragraph("<b>Layer 1: Platform Foundation</b><br/><font size='10'>Deploy ONCE - Shared Resources</font>", self.styles['SlideBody'])],
            [Paragraph("""
            • 5 Shared User-Assigned Managed Identities (UAMIs)<br/>
            • External Secrets, External DNS, Cert Manager, Grafana, Flux<br/>
            • Central Resource Group for platform-wide resources<br/>
            • Single RBAC assignment point for all clusters
            """, self.styles['BulletPoint'])],
        ]

        t1 = Table(arch_data, colWidths=[9*inch])
        t1.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), HexColor('#E8F4E8')),
            ('TEXTCOLOR', (0, 0), (-1, 0), HexColor('#155724')),
            ('BOX', (0, 0), (-1, -1), 2, ACCENT_GREEN),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
        ]))
        elements.append(t1)
        elements.append(Spacer(1, 0.15*inch))

        # Layer 2
        arch_data2 = [
            [Paragraph("<b>Layer 2: Management Cluster</b><br/><font size='10'>Deploy ONCE per Management Group</font>", self.styles['SlideBody'])],
            [Paragraph("""
            • AKS Management Cluster with KRO, ASO, Flux installed<br/>
            • Federated Identity Credentials linked to shared UAMIs<br/>
            • Service Accounts for workload identity<br/>
            • Platform controllers (cert-manager, external-dns, ESO)
            """, self.styles['BulletPoint'])],
        ]

        t2 = Table(arch_data2, colWidths=[9*inch])
        t2.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), HexColor('#FFF3CD')),
            ('TEXTCOLOR', (0, 0), (-1, 0), HexColor('#856404')),
            ('BOX', (0, 0), (-1, -1), 2, ACCENT_ORANGE),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
        ]))
        elements.append(t2)
        elements.append(Spacer(1, 0.15*inch))

        # Layer 3
        arch_data3 = [
            [Paragraph("<b>Layer 3: Worker Clusters</b><br/><font size='10'>Deploy PER CLUSTER - Unlimited Scale</font>", self.styles['SlideBody'])],
            [Paragraph("""
            • AKS Worker Clusters for application workloads<br/>
            • References SAME shared UAMIs from Layer 1<br/>
            • Federated Credentials bind UAMIs to cluster OIDC<br/>
            • Simple YAML to add new clusters in minutes
            """, self.styles['BulletPoint'])],
        ]

        t3 = Table(arch_data3, colWidths=[9*inch])
        t3.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), LIGHT_BLUE),
            ('TEXTCOLOR', (0, 0), (-1, 0), DARK_BLUE),
            ('BOX', (0, 0), (-1, -1), 2, PRIMARY_BLUE),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
        ]))
        elements.append(t3)

        elements.append(PageBreak())
        return elements

    def create_gitops_slide(self):
        """Create GitOps workflow slide"""
        elements = []
        elements.append(Paragraph("GitOps Workflow", self.styles['SlideTitle']))
        elements.append(Paragraph("Infrastructure as Code Pipeline", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Workflow steps
        workflow_data = [
            ["1", "Developer", "Commits cluster YAML to Git repository"],
            ["2", "Pull Request", "Code review + policy validation gates"],
            ["3", "Merge to Main", "Triggers Flux CD sync on management cluster"],
            ["4", "KRO Controller", "Reconciles ResourceGraphDefinition"],
            ["5", "ASO Controller", "Provisions Azure resources (AKS, UAMIs, etc.)"],
            ["6", "Certification", "Argo Workflow validates deployment"],
        ]

        table_data = []
        for row in workflow_data:
            table_data.append([
                Paragraph(f"<b>{row[0]}</b>", ParagraphStyle(
                    name='Num',
                    parent=self.styles['Normal'],
                    fontSize=18,
                    textColor=white,
                    alignment=TA_CENTER
                )),
                Paragraph(f"<b>{row[1]}</b>", self.styles['SlideBody']),
                Paragraph(row[2], self.styles['BulletPoint'])
            ])

        t = Table(table_data, colWidths=[0.6*inch, 1.8*inch, 6*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, -1), PRIMARY_BLUE),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 10),
            ('RIGHTPADDING', (0, 0), (-1, -1), 10),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
            ('LINEBELOW', (0, 0), (-1, -2), 0.5, LIGHT_GRAY),
            ('ROUNDEDCORNERS', [5, 5, 5, 5]),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Key benefit box
        elements.append(Paragraph(
            "<b>Key Benefit:</b> Every infrastructure change is versioned, reviewed, and auditable. "
            "Disaster recovery is as simple as re-syncing from Git.",
            ParagraphStyle(
                name='KeyBenefit',
                parent=self.styles['Normal'],
                fontSize=14,
                textColor=DARK_BLUE,
                backColor=LIGHT_BLUE,
                borderPadding=15,
                alignment=TA_CENTER
            )
        ))

        elements.append(PageBreak())
        return elements

    def create_kyverno_slide(self):
        """Create Kyverno policy management slide"""
        elements = []
        elements.append(Paragraph("Kyverno Policy Management", self.styles['SlideTitle']))
        elements.append(Paragraph("Security & Compliance Governance", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Policy areas
        policy_areas = [
            ["Admission Control", "• Validates all Kubernetes resources before creation\n• Enforces naming conventions and labels\n• Blocks non-compliant configurations"],
            ["Security Policies", "• Pod Security Standards enforcement\n• Network policy requirements\n• Image registry restrictions"],
            ["Resource Governance", "• Resource quota enforcement\n• Namespace isolation rules\n• Storage class restrictions"],
            ["Audit & Compliance", "• Real-time policy violation alerts\n• Compliance reporting dashboards\n• Drift detection and remediation"],
        ]

        table_data = []
        for area in policy_areas:
            table_data.append([
                Paragraph(f"<b>{area[0]}</b>", ParagraphStyle(
                    name='PolicyArea',
                    parent=self.styles['Normal'],
                    fontSize=14,
                    textColor=white,
                    alignment=TA_CENTER
                )),
                Paragraph(area[1].replace('\n', '<br/>'), self.styles['BulletPoint'])
            ])

        t = Table(table_data, colWidths=[2.2*inch, 7*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, -1), PRIMARY_BLUE),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('RIGHTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 12),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 12),
            ('LINEBELOW', (0, 0), (-1, -2), 1, LIGHT_GRAY),
            ('BOX', (0, 0), (-1, -1), 2, PRIMARY_BLUE),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Integration note
        elements.append(Paragraph(
            "<b>Integration:</b> Kyverno policies are stored in Git and deployed via Flux, "
            "ensuring policy-as-code consistency across all management groups.",
            ParagraphStyle(
                name='IntNote',
                parent=self.styles['Normal'],
                fontSize=13,
                textColor=HexColor('#155724'),
                backColor=HexColor('#D4EDDA'),
                borderPadding=15,
                alignment=TA_CENTER
            )
        ))

        elements.append(PageBreak())
        return elements

    def create_mgmt_cluster_slide(self):
        """Create management cluster strategy slide"""
        elements = []
        elements.append(Paragraph("Management Cluster Strategy", self.styles['SlideTitle']))
        elements.append(Paragraph("One Management Cluster per Management Group", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Diagram as nested tables
        mg_data = [
            [
                Paragraph("<b>Management Group: Production</b>", self.styles['SectionHeader']),
                Paragraph("<b>Management Group: Non-Production</b>", self.styles['SectionHeader'])
            ],
            [
                Paragraph("""
                <b>Management Cluster (1)</b><br/>
                • KRO Controller<br/>
                • Azure Service Operator<br/>
                • Flux CD + Kyverno Policies<br/><br/>
                <b>Worker Clusters (N)</b><br/>
                • prod-app-cluster-001<br/>
                • prod-app-cluster-002<br/>
                • prod-data-cluster-001
                """, self.styles['BulletPoint']),
                Paragraph("""
                <b>Management Cluster (1)</b><br/>
                • KRO Controller<br/>
                • Azure Service Operator<br/>
                • Flux CD + Kyverno Policies<br/><br/>
                <b>Worker Clusters (N)</b><br/>
                • dev-test-cluster-001<br/>
                • staging-cluster-001<br/>
                • qa-cluster-001
                """, self.styles['BulletPoint'])
            ]
        ]

        t = Table(mg_data, colWidths=[4.5*inch, 4.5*inch])
        t.setStyle(TableStyle([
            ('BOX', (0, 0), (0, -1), 2, ACCENT_GREEN),
            ('BOX', (1, 0), (1, -1), 2, ACCENT_ORANGE),
            ('BACKGROUND', (0, 0), (0, 0), HexColor('#E8F4E8')),
            ('BACKGROUND', (1, 0), (1, 0), HexColor('#FFF3CD')),
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('RIGHTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Benefits
        benefits = [
            ["Blast Radius Isolation", "Issues in non-prod don't affect production"],
            ["Policy Separation", "Different Kyverno policies per environment tier"],
            ["RBAC Boundaries", "Azure AD groups scoped to management groups"],
            ["Cost Attribution", "Clear subscription/cost center mapping"],
        ]

        benefit_data = [[Paragraph(f"<b>{b[0]}:</b> {b[1]}", self.styles['BulletPoint'])] for b in benefits]
        t2 = Table(benefit_data, colWidths=[9*inch])
        t2.setStyle(TableStyle([
            ('LEFTPADDING', (0, 0), (-1, -1), 20),
        ]))
        elements.append(t2)

        elements.append(PageBreak())
        return elements

    def create_azure_ad_slide(self):
        """Create Azure AD integration slide"""
        elements = []
        elements.append(Paragraph("Azure AD Integration", self.styles['SlideTitle']))
        elements.append(Paragraph("Identity & Access Management", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Identity flow
        identity_data = [
            ["Component", "Identity Type", "Purpose"],
            ["AKS Control Plane", "User-Assigned MI", "Cluster operations, Azure API access"],
            ["Kubelet", "User-Assigned MI", "Node operations, ACR image pull"],
            ["External Secrets", "Workload Identity", "Key Vault secret access"],
            ["External DNS", "Workload Identity", "DNS zone record management"],
            ["Cert Manager", "Workload Identity", "Certificate issuance"],
            ["Flux Controllers", "Workload Identity", "Git repo + ACR access"],
        ]

        t = Table(identity_data, colWidths=[2.5*inch, 2.5*inch, 4*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), DARK_BLUE),
            ('TEXTCOLOR', (0, 0), (-1, 0), white),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('ALIGN', (0, 0), (-1, 0), 'CENTER'),
            ('FONTSIZE', (0, 0), (-1, -1), 12),
            ('BACKGROUND', (0, 1), (-1, -1), LIGHT_GRAY),
            ('GRID', (0, 0), (-1, -1), 0.5, white),
            ('TOPPADDING', (0, 0), (-1, -1), 10),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 10),
            ('LEFTPADDING', (0, 0), (-1, -1), 10),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # AAD Groups
        elements.append(Paragraph("<b>Azure AD Group-Based Access</b>", self.styles['SectionHeader']))

        aad_groups = [
            ["AKS Cluster Admins", "Full cluster admin access via Azure RBAC"],
            ["Platform Engineers", "KRO/ASO management, cluster provisioning"],
            ["Application Teams", "Namespace-scoped access, workload deployment"],
            ["Security/Audit", "Read-only access for compliance monitoring"],
        ]

        aad_data = [[Paragraph(f"<b>{g[0]}:</b> {g[1]}", self.styles['BulletPoint'])] for g in aad_groups]
        t2 = Table(aad_data, colWidths=[9*inch])
        elements.append(t2)

        elements.append(PageBreak())
        return elements

    def create_certification_slide(self):
        """Create certification and validation slide"""
        elements = []
        elements.append(Paragraph("Automated Certification", self.styles['SlideTitle']))
        elements.append(Paragraph("Argo Workflows Validation Pipeline", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # Certification sections
        cert_sections = [
            ["1", "Configuration", "Validates cluster YAML and parameters"],
            ["2", "KRO Resources", "Checks ResourceGraphDefinitions are Active"],
            ["3", "ASO Resources", "Verifies Azure resources are Ready"],
            ["4", "Flux GitOps", "Confirms Flux controllers are running"],
            ["5", "Connectivity", "Tests API server and node health"],
            ["6", "Security", "Validates workload identity and policies"],
        ]

        table_data = []
        for section in cert_sections:
            table_data.append([
                Paragraph(section[0], ParagraphStyle(
                    name='CertNum',
                    parent=self.styles['Normal'],
                    fontSize=16,
                    textColor=white,
                    alignment=TA_CENTER
                )),
                Paragraph(f"<b>{section[1]}</b>", self.styles['SlideBody']),
                Paragraph(section[2], self.styles['BulletPoint'])
            ])

        t = Table(table_data, colWidths=[0.5*inch, 2*inch, 6*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, -1), ACCENT_GREEN),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 10),
            ('TOPPADDING', (0, 0), (-1, -1), 8),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 8),
            ('LINEBELOW', (0, 0), (-1, -2), 0.5, LIGHT_GRAY),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Timing
        timing_data = [
            ["Total Duration", "~70 seconds"],
            ["Trigger", "Automatic on deployment + Weekly scheduled"],
            ["Output", "JSON certification report + Argo UI dashboard"],
        ]

        t2 = Table(timing_data, colWidths=[2.5*inch, 6.5*inch])
        t2.setStyle(TableStyle([
            ('FONTNAME', (0, 0), (0, -1), 'Helvetica-Bold'),
            ('BACKGROUND', (0, 0), (0, -1), LIGHT_BLUE),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 8),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 8),
            ('BOX', (0, 0), (-1, -1), 1, PRIMARY_BLUE),
        ]))
        elements.append(t2)

        elements.append(PageBreak())
        return elements

    def create_benefits_slide(self):
        """Create benefits slide"""
        elements = []
        elements.append(Paragraph("Benefits & Value", self.styles['SlideTitle']))
        elements.append(Paragraph("Business Value Summary", self.styles['SlideSubtitle']))
        elements.append(Spacer(1, 0.2*inch))

        # ROI metrics
        roi_data = [
            ["90%", "Reduction in identity management overhead"],
            ["10x", "Faster disaster recovery time"],
            ["100%", "Policy compliance enforcement"],
            ["~70s", "Automated certification per cluster"],
        ]

        roi_table = []
        for metric in roi_data:
            roi_table.append([
                Paragraph(f"<b>{metric[0]}</b>", ParagraphStyle(
                    name='BigNum',
                    parent=self.styles['Normal'],
                    fontSize=28,
                    textColor=PRIMARY_BLUE,
                    alignment=TA_CENTER,
                    fontName='Helvetica-Bold'
                )),
                Paragraph(metric[1], self.styles['SlideBody'])
            ])

        t = Table(roi_table, colWidths=[1.5*inch, 3*inch] * 2)
        t.setStyle(TableStyle([
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 10),
            ('TOPPADDING', (0, 0), (-1, -1), 15),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 15),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.3*inch))

        # Key benefits summary
        elements.append(Paragraph("<b>Key Benefits</b>", self.styles['SectionHeader']))

        benefits = [
            "<b>Operational Efficiency:</b> Single management cluster manages unlimited worker clusters",
            "<b>Security Posture:</b> Kyverno policies enforced at admission, preventing drift",
            "<b>Developer Experience:</b> Simple YAML to provision complete AKS clusters",
            "<b>Audit & Compliance:</b> Complete Git history + automated certification",
            "<b>Cost Optimization:</b> Shared identities reduce Azure AD object sprawl",
        ]

        for benefit in benefits:
            elements.append(Paragraph(f"• {benefit}", self.styles['BulletPoint']))

        elements.append(PageBreak())
        return elements

    def create_next_steps_slide(self):
        """Create next steps / call to action slide"""
        elements = []
        elements.append(Paragraph("Next Steps", self.styles['SlideTitle']))
        elements.append(Spacer(1, 0.3*inch))

        steps = [
            ["Phase 1", "Pilot Deployment", "Deploy platform foundation + 1 management cluster in non-prod"],
            ["Phase 2", "Policy Rollout", "Configure Kyverno policies for security baseline"],
            ["Phase 3", "Production Ready", "Deploy production management group infrastructure"],
            ["Phase 4", "Scale Out", "Add worker clusters as needed via GitOps"],
        ]

        table_data = []
        colors_list = [ACCENT_GREEN, PRIMARY_BLUE, ACCENT_ORANGE, DARK_BLUE]
        for i, step in enumerate(steps):
            table_data.append([
                Paragraph(f"<b>{step[0]}</b>", ParagraphStyle(
                    name='Phase',
                    parent=self.styles['Normal'],
                    fontSize=14,
                    textColor=white,
                    alignment=TA_CENTER
                )),
                Paragraph(f"<b>{step[1]}</b><br/><font size='11'>{step[2]}</font>", self.styles['SlideBody'])
            ])

        t = Table(table_data, colWidths=[1.2*inch, 7.5*inch])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, 0), ACCENT_GREEN),
            ('BACKGROUND', (0, 1), (0, 1), PRIMARY_BLUE),
            ('BACKGROUND', (0, 2), (0, 2), ACCENT_ORANGE),
            ('BACKGROUND', (0, 3), (0, 3), DARK_BLUE),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 15),
            ('TOPPADDING', (0, 0), (-1, -1), 15),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 15),
            ('LINEBELOW', (0, 0), (-1, -2), 1, LIGHT_GRAY),
        ]))
        elements.append(t)

        elements.append(Spacer(1, 0.5*inch))

        # Contact / Resources
        elements.append(Paragraph(
            "<b>Resources:</b> GitHub Repository | Architecture Docs | Runbooks",
            ParagraphStyle(
                name='Resources',
                parent=self.styles['Normal'],
                fontSize=14,
                textColor=GRAY,
                alignment=TA_CENTER
            )
        ))

        elements.append(Spacer(1, 0.3*inch))

        elements.append(Paragraph(
            "Questions?",
            ParagraphStyle(
                name='Questions',
                parent=self.styles['Normal'],
                fontSize=28,
                textColor=PRIMARY_BLUE,
                alignment=TA_CENTER,
                fontName='Helvetica-Bold'
            )
        ))

        return elements

    def generate(self):
        """Generate the complete PDF"""
        doc = SimpleDocTemplate(
            self.filename,
            pagesize=landscape(LETTER),
            topMargin=0.75*inch,
            bottomMargin=0.75*inch,
            leftMargin=0.5*inch,
            rightMargin=0.5*inch
        )

        # Build content
        elements = []
        elements.extend(self.create_title_slide())
        elements.extend(self.create_agenda_slide())
        elements.extend(self.create_executive_summary())
        elements.extend(self.create_architecture_slide())
        elements.extend(self.create_gitops_slide())
        elements.extend(self.create_kyverno_slide())
        elements.extend(self.create_mgmt_cluster_slide())
        elements.extend(self.create_azure_ad_slide())
        elements.extend(self.create_certification_slide())
        elements.extend(self.create_benefits_slide())
        elements.extend(self.create_next_steps_slide())

        # Build PDF with header/footer
        doc.build(elements, onFirstPage=self.draw_header_footer, onLaterPages=self.draw_header_footer)
        print(f"✅ PDF generated: {self.filename}")


if __name__ == "__main__":
    # Generate the presentation
    output_dir = os.path.dirname(os.path.abspath(__file__))
    output_file = os.path.join(output_dir, "UK8S-KRO-Stack-Presentation.pdf")

    presenter = KROPresentationPDF(output_file)
    presenter.generate()

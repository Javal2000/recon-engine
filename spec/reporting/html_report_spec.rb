# frozen_string_literal: true

RSpec.describe ReconEngine::Reporting::HtmlReport do
  let(:dir) { Dir.mktmpdir }
  let(:manifest) { ReconEngine::Generator.new(seed: 11, rows: 300).write(dir) }
  let(:report) do
    ReconEngine::Run.call(ledger_path: manifest["paths"]["ledger"], warehouse_path: manifest["paths"]["warehouse"])
  end

  after { FileUtils.remove_entry(dir) }

  def html_for(a_report) = described_class.new(a_report).render

  # The same report with its first finding replaced, as if a model had
  # returned markup instead of prose.
  def with_first_finding(a_report, **changes)
    findings = [a_report.findings.first.with(**changes), *a_report.findings.drop(1)]
    fields = %i[config inputs ledger_profile warehouse_profile match_result breaks clusters started_at
                duration_seconds].to_h { |name| [name, a_report.public_send(name)] }
    ReconEngine::Reporting::Report.new(**fields, findings: findings)
  end

  it "renders the summary, every cluster and the fingerprint" do
    html = html_for(report)

    expect(html).to include("Reconciliation report", "Where the money is", report.deterministic_fingerprint)
    expect(html).to include(*report.clusters.map(&:id))
    expect(html).to include("EXPLAINED")
  end

  it "is self-contained: no scripts and nothing fetched from elsewhere" do
    html = html_for(report)

    expect(html).not_to match(/<script|<link|https?:/i)
  end

  # An explanation is text a model wrote. It must never reach the page as markup.
  it "escapes whatever the model returned" do
    evil    = %(<script>alert("x")</script><img src=x onerror=alert(1)>)
    html    = html_for(with_first_finding(report, explanation: evil, evidence: [evil]))

    expect(html).not_to include("<script>", "<img")
    expect(html).to include("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;")
  end

  it "says so when the two files reconcile" do
    ledger = manifest["paths"]["ledger"]
    clean  = ReconEngine::Run.call(ledger_path: ledger, warehouse_path: ledger)

    expect(html_for(clean)).to include("Reconciled clean")
  end

  it "writes the page to disk, creating the directory" do
    path = File.join(dir, "nested", "report.html")
    described_class.write(report, path)

    expect(File.read(path)).to start_with("<!doctype html>")
  end
end

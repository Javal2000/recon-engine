# frozen_string_literal: true

RSpec.describe ReconEngine::Evaluation do
  let(:evaluation) { described_class.new(manifest: {}, report: nil) }

  def outcome(correct:, confidence: 0.9, answered: true, kind: "missing")
    described_class::Outcome.new(kind: kind, expected: "MISSING_IN_TARGET",
                                 actual: correct ? "MISSING_IN_TARGET" : "ROUNDING",
                                 confidence: answered ? confidence : nil, answered: answered)
  end

  def with_outcomes(list)
    allow(evaluation).to receive(:outcomes).and_return(list)
  end

  it "measures how far stated confidence is from observed accuracy" do
    with_outcomes([outcome(correct: true, confidence: 0.95), outcome(correct: false, confidence: 0.95)])

    band = evaluation.calibration[:bands].first
    expect(band).to include(band: "0.9-1.0", breaks: 2, mean_confidence: 0.95, accuracy: 0.5)
    expect(evaluation.calibration[:expected_calibration_error]).to eq(0.45)
  end

  it "puts a confidence of exactly 1.0 in the top band" do
    with_outcomes([outcome(correct: true, confidence: 1.0)])

    expect(evaluation.calibration[:bands].map { |b| b[:band] }).to eq(["0.9-1.0"])
    expect(evaluation.calibration[:expected_calibration_error]).to eq(0.0)
  end

  # A provider that ran out of quota should read as low coverage, not as a
  # model that answered badly.
  it "keeps unanswered breaks out of calibration but counts them against recall" do
    with_outcomes([outcome(correct: true), outcome(correct: false, answered: false)])

    expect(evaluation.overall_recall).to eq(0.5)
    expect(evaluation.coverage).to eq(0.5)
    expect(evaluation.calibration[:bands].sum { |b| b[:breaks] }).to eq(1)
  end

  it "reports recall per fault kind" do
    with_outcomes([outcome(correct: true, kind: "missing"), outcome(correct: false, kind: "missing"),
                   outcome(correct: true, kind: "orphan")])

    expect(evaluation.recall_by_kind["missing"]).to include(breaks: 2, correct: 1, recall: 0.5)
    expect(evaluation.recall_by_kind["orphan"]).to include(breaks: 1, correct: 1, recall: 1.0)
  end
end

# frozen_string_literal: true

RSpec.describe ReconEngine::Money do
  describe ".to_cents" do
    it "parses decimal strings exactly" do
      expect(described_class.to_cents("1234.56")).to eq(123_456)
      expect(described_class.to_cents("-0.01")).to eq(-1)
      expect(described_class.to_cents("0.00")).to eq(0)
    end

    it "tolerates thousands separators and a leading plus" do
      expect(described_class.to_cents("1,234.56")).to eq(123_456)
      expect(described_class.to_cents("+42.00")).to eq(4_200)
    end

    # Each of these is exact in cents and wrong in floats.
    it "does not accumulate floating point error" do
      cents = %w[0.10 0.20 0.30].sum { |v| described_class.to_cents(v) }
      expect(cents).to eq(60)
      expect(described_class.to_cents("0.10") + described_class.to_cents("0.20"))
        .to eq(described_class.to_cents("0.30"))
    end

    it "rejects anything that is not a decimal number" do
      ["", "  ", "abc", "12.34.56", "1e5", nil].each do |bad|
        expect { described_class.to_cents(bad) }.to raise_error(ReconEngine::InputError)
      end
    end
  end

  describe ".format" do
    it "round-trips through to_cents" do
      ["0.00", "-0.01", "1234.56", "-9999.99"].each do |value|
        expect(described_class.format(described_class.to_cents(value))).to eq(value)
      end
    end

    it "zero-pads the minor units" do
      expect(described_class.format(5)).to eq("0.05")
      expect(described_class.format(-5)).to eq("-0.05")
      expect(described_class.format(100)).to eq("1.00")
    end
  end

  describe ".humanize" do
    it "groups thousands" do
      expect(described_class.humanize(123_456_789)).to eq("$1,234,567.89")
      expect(described_class.humanize(-100)).to eq("-$1.00")
    end
  end

  describe ".within_tolerance?" do
    it "is inclusive at the boundary" do
      expect(described_class.within_tolerance?(100, 101, 1)).to be(true)
      expect(described_class.within_tolerance?(100, 102, 1)).to be(false)
      expect(described_class.within_tolerance?(100, 100, 0)).to be(true)
    end
  end
end

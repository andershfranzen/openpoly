#!/usr/bin/env ruby
# Offline parser only: never loads, executes, emulates, or flashes firmware.
require 'digest'
require 'fileutils'
require 'optparse'

OFFICIAL_SHA256 = 'bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5'
MAIN_SHA256 = '89d66525c9bf51c96ba949f31e98a39dc26c60710a2299b09c3608ea8177f689'
LOAD_BASE = 0x50000

def parse_container(input, expected_hash)
  raise 'SHA-256 mismatch' unless Digest::SHA256.hexdigest(input) == expected_hash
  raise 'truncated container header' if input.bytesize < 0x80
  raise 'invalid FIRMWARE signature' unless input.byteslice(0, 8) == 'FIRMWARE'
  raise 'invalid APP_MAIN section' unless input.byteslice(0x20, 8) == 'APP_MAIN'
  raise 'invalid APP_DSP section' unless input.byteslice(0x40, 7) == 'APP_DSP'
  offset, length = input.byteslice(0x34, 8).unpack('V2')
  dsp_offset, dsp_length = input.byteslice(0x54, 8).unpack('V2')
  [[offset, length], [dsp_offset, dsp_length]].each do |start, size|
    raise 'section outside container bounds' unless start >= 0x80 && size >= 8 && start <= input.bytesize && size <= input.bytesize - start
  end
  raise 'overlapping sections' unless offset + length <= dsp_offset || dsp_offset + dsp_length <= offset
  code = input.byteslice(offset, length)
  stack, reset = code.byteslice(0, 8).unpack('V2')
  raise 'invalid initial stack address' unless (0x20000000...0x20010000).cover?(stack)
  raise 'invalid Thumb reset vector' unless reset.odd? && (LOAD_BASE...(LOAD_BASE + length)).cover?(reset & ~1)
  [code, offset, reset]
end

def wrap_elf(code, reset)
  names = "\0.text\0.shstrtab\0".b
  strings_offset = 52 + code.bytesize
  sections_offset = (strings_offset + names.bytesize + 3) & ~3
  ident = "\x7fELF".b + [1, 1, 1, 0, 0].pack('C*') + "\0" * 7
  header = ident + [2, 40, 1, reset, 0, sections_offset, 0x05000200, 52, 0, 0, 40, 3, 2].pack('vvVVVVVvvvvvv')
  elf = header + code + names
  elf << "\0" * (sections_offset - elf.bytesize)
  elf << "\0" * 40
  elf << [1, 1, 6, LOAD_BASE, 52, code.bytesize, 0, 0, 4, 0].pack('V10')
  elf << [7, 3, 0, 0, strings_offset, names.bytesize, 0, 0, 1, 0].pack('V10')
end

def self_test(input, code, offset, reset, elf)
  raise 'self-test requires the documented official image' unless Digest::SHA256.hexdigest(input) == OFFICIAL_SHA256
  raise 'APP_MAIN extraction regression' unless offset == 0x80 && code.bytesize == 0x7e84c && Digest::SHA256.hexdigest(code) == MAIN_SHA256
  raise 'reset mapping regression' unless reset == 0x5ced9 && code.byteslice((reset & ~1) - LOAD_BASE, 4) == [0x70, 0xb5, 0x72, 0xb6].pack('C*')
  anchor = 'SetStatusAndSidePanelBrightness '
  raise 'LED string mapping regression' unless code.byteslice(0xb1f54 - LOAD_BASE, anchor.bytesize) == anchor
  raise 'ELF wrapper regression' unless Digest::SHA256.hexdigest(elf) == 'e3cb113a4c575107a29411088b00ecfc1f9a6b538160f20829bbf42f0a4e4219'
  puts 'Self-test passed: extraction, reset mapping, LED anchor, ELF bytes.'
end

begin
  options = { expected_hash: OFFICIAL_SHA256 }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby script/firmware-inspect.rb [options] DFU_IMAGE'
    opts.on('--output-dir DIR', 'Write APP_MAIN.bin and APP_MAIN.thumb.elf (must not already exist)') { |v| options[:output_dir] = v }
    opts.on('--expected-sha256 HEX', 'Expected container SHA-256; defaults to the documented official image') { |v| options[:expected_hash] = v.downcase }
    opts.on('--self-test', 'Check documented official-image anchors and wrapper hash') { options[:self_test] = true }
    opts.on('-h', '--help', 'Show usage') { puts opts; exit }
  end
  parser.parse!
  raise parser.to_s unless ARGV.length == 1
  raise 'expected SHA-256 must be 64 hexadecimal digits' unless options[:expected_hash].match?(/\A[0-9a-f]{64}\z/)
  input = File.binread(ARGV.fetch(0))
  code, offset, reset = parse_container(input, options[:expected_hash])
  elf = wrap_elf(code, reset)
  self_test(input, code, offset, reset, elf) if options[:self_test]
  puts 'Container SHA-256: ' + Digest::SHA256.hexdigest(input)
  puts 'APP_MAIN offset=0x%x length=0x%x load=0x%x reset=0x%x' % [offset, code.bytesize, LOAD_BASE, reset]
  puts 'APP_MAIN SHA-256: ' + Digest::SHA256.hexdigest(code)
  puts 'ELF SHA-256: ' + Digest::SHA256.hexdigest(elf)
  if options[:output_dir]
    paths = %w[APP_MAIN.bin APP_MAIN.thumb.elf].map { |name| File.join(options[:output_dir], name) }
    raise 'output already exists' if paths.any? { |path| File.exist?(path) || File.symlink?(path) }
    FileUtils.mkdir_p(options[:output_dir])
    paths.zip([code, elf]).each { |path, bytes| File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) } }
    puts 'Wrote: ' + paths.join(', ')
  end
rescue StandardError => error
  warn 'firmware-inspect: ' + error.message
  exit 1
end

require "google/apis/gmail_v1"
require "googleauth"
require "googleauth/stores/file_token_store"
require "fileutils"

require "combine_pdf"
require "erb"

OOB_URI = "urn:ietf:wg:oauth:2.0:oob".freeze
APPLICATION_NAME = "Gmail API Ruby Quickstart".freeze
CREDENTIALS_PATH = "credentials.json".freeze
# The file token.yaml stores the user's access and refresh tokens, and is
# created automatically when the authorization flow completes for the first
# time.
TOKEN_PATH = "token.yaml".freeze
SCOPE = Google::Apis::GmailV1::AUTH_GMAIL_READONLY

##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization. If authorization is required,
# the user's default browser will be launched to approve the request.
#
# @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
def authorize
  client_id = Google::Auth::ClientId.from_file CREDENTIALS_PATH
  token_store = Google::Auth::Stores::FileTokenStore.new file: TOKEN_PATH
  authorizer = Google::Auth::UserAuthorizer.new client_id, SCOPE, token_store
  user_id = "default"
  credentials = authorizer.get_credentials user_id
  if credentials.nil?
    url = authorizer.get_authorization_url base_url: OOB_URI
    puts "Open the following URL in the browser and enter the resulting code after authorization:"
    puts url
    puts ""
    puts "paste code here:"
    code = gets

    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: OOB_URI
    )
  end
  credentials
end

# Initialize the API
$gmail = Google::Apis::GmailV1::GmailService.new
$gmail.client_options.application_name = APPLICATION_NAME
$gmail.authorization = authorize

raise "query missing" unless ARGV[0]

gmail_user_messages = $gmail.list_user_messages "me", q: ARGV[0]

def process(msg, payload, counter)
  if payload.parts
    for part in payload.parts do
      process msg, part, counter
      counter = counter + 1
    end
  else
    render(msg, payload)
    if File.exist? "tmp/render.pdf"
      FileUtils.mv "tmp/render.pdf", "pages/#{counter}.pdf"
    end
  end
end

require "fileutils"
def render(msg, payload)
  case payload.mime_type
  when "text/plain"
    return if payload.body.data == "\r\n\r\n"
    return if payload.body.data == "\r\n"
    puts "TEXT:"
    p payload.body.data

    template = ERB.new(File.read('templates/text.erb'))
    output = template.result_with_hash({ body: payload.body.data })
    File.write "tmp/render.html", output
  when "text/html"
    File.write "tmp/render.html", payload.body.data
  when "jpg","image/jpeg", "image/png", "application/pdf", "application/octetstream", "application/octet-stream"
    file_extension = payload.filename.split(".").last.downcase

    gmail_contents = $gmail.get_user_message_attachment "me", msg.id, payload.body.attachment_id
    File.write "tmp/render.#{file_extension}", gmail_contents.data

    case file_extension
    when "pdf"
    when "jpg","jpeg","png"
      template = ERB.new(File.read('templates/image.erb'))
      output = template.result_with_hash({ image_file: "render.#{file_extension}"})

      File.write "tmp/render.html", output
    else
      p payload
      raise file_extension
    end
  when "text/calendar"
    p "wut"
  else
    p payload.mime_type
    raise "err"
  end

  if File.exist? "tmp/render.html"
    `wkhtmltopdf --margin-left 10 --margin-right 10 --margin-top 10 --margin-bottom 10 tmp/render.html tmp/render.pdf`
    File.unlink "tmp/render.html"
  end
end

gmail_user_messages.messages.each do |msg|
  gmail_message = $gmail.get_user_message 'me', msg.id

  for gmail_header in gmail_message.payload.headers do
    from = gmail_header.value if gmail_header.name == "From"
    to = gmail_header.value if gmail_header.name == "To"
    subject = gmail_header.value if gmail_header.name == "Subject"
  end
  p [to, from, subject]

  FileUtils.rm_rf "tmp"
  FileUtils.mkdir "tmp"
  FileUtils.rm_rf "pages"
  FileUtils.mkdir "pages"

  pdf = CombinePDF.new
  process(gmail_message, gmail_message.payload, 1)
  Dir.glob("pages/*.pdf").sort.each do |page|
    pdf << CombinePDF.load(page)
  rescue CombinePDF::ParsingError
    FileUtils.cp page, "combined_#{msg.id}_#{(rand*10000).floor}.pdf"
  end
  pdf.save "combined_#{msg.id}.pdf"
end

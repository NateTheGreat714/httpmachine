using System;

namespace HttpMachine
{
    public class HttpParser
    {
		int[] stack = new int[3];
		int top = 0;
        int cs;
        int mark;
        int qsMark;
        int fragMark;
        IHttpParserHandler parser;

		int versionMajor = 0;
		int versionMinor = 9;

		public int MajorVersion { get { return versionMajor; } }
		public int MinorVersion { get { return versionMinor; } }

		bool gotConnectionClose;
		bool gotConnectionKeepAlive;
		bool shouldKeepAlive;

        // internal for testing
        internal int contentLength = -1;

		public bool ShouldKeepAlive { 
			get { 
				if (versionMajor > 0 && versionMinor > 0)
					// HTTP/1.1
					return !gotConnectionClose;
				else 
					// < HTTP/1.1
					return gotConnectionKeepAlive;
			}
		}


        %%{

        # define actions
        machine http_parser;

		action message_begin {
			Console.WriteLine("message_begin");
			parser.OnMessageBegin(this);
		}
        
        action matched_absolute_uri {
            Console.WriteLine("matched absolute_uri");
        }
        action matched_abs_path {
            Console.WriteLine("matched abs_path");
        }
        action matched_authority {
            Console.WriteLine("matched authority");
        }
        action matched_first_space {
            Console.WriteLine("matched first space");
        }
		action matched_header { 
			Console.WriteLine("matched header");
		}
		action matched_last_crlf_before_body {
			Console.WriteLine("matched_last_crlf_before_body");
		}

        action enter_method {
            mark = fpc;
        }
        
        action eof_leave_method {
            //Console.WriteLine("eof_leave_method fpc " + fpc + " mark " + mark);
            parser.OnMethod(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }

        action leave_method {
            //Console.WriteLine("leave_method fpc " + fpc + " mark " + mark);
            parser.OnMethod(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }
        
        action enter_request_uri {
            //Console.WriteLine("enter_request_uri fpc " + fpc);
            mark = fpc;
        }
        
        action eof_leave_request_uri {
            //Console.WriteLine("eof_leave_request_uri!! fpc " + fpc + " mark " + mark);
            parser.OnRequestUri(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }

        action leave_request_uri {
            //Console.WriteLine("leave_request_uri fpc " + fpc + " mark " + mark);
            parser.OnRequestUri(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }
        
        action enter_query_string {
            //Console.WriteLine("enter_query_string fpc " + fpc);
            qsMark = fpc;
        }

        action leave_query_string {
            //Console.WriteLine("leave_query_string fpc " + fpc + " qsMark " + qsMark);
            parser.OnQueryString(this, new ArraySegment<byte>(data, qsMark, fpc - qsMark));
        }
        action enter_fragment {
            //Console.WriteLine("enter_fragment fpc " + fpc);
            fragMark = fpc;
        }

        action leave_fragment {
            //Console.WriteLine("leave_fragment fpc " + fpc + " fragMark " + fragMark);
            parser.OnFragment(this, new ArraySegment<byte>(data, fragMark, fpc - fragMark));
        }

        action version_major {
			versionMajor = (char)fc - '0';
		}

		action version_minor {
			versionMinor = (char)fc - '0';
		}
        
        action enter_header_name {
            //Console.WriteLine("enter_header_name fpc " + fpc + " fc " + (char)fc);
            mark = fpc;
        }
        
        action leave_header_name {
            //Console.WriteLine("leave_header_name fpc " + fpc + " fc " + (char)fc);
            parser.OnHeaderName(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }

        action leave_header_content_length {
            if (contentLength != -1) throw new Exception("Already got Content-Length. Possible attack?");
			contentLength = 0;
        }
		
		action leave_header_transfer_encoding {
		}

		action leave_header_connection {
		}

		action leave_header_upgrade {
		}
        
        action enter_header_value {
            //Console.WriteLine("enter_header_value fpc " + fpc + " fc " + (char)fc);
            mark = fpc;
        }

        action header_value_char {
            //Console.WriteLine("header_value_char fpc " + fpc + " fc " + (char)fc);
            if (contentLength > -1)
            {
                var cfc = (char)fc;
                if (cfc == ' ')
                {
                    fbreak;
                }

                if (cfc < '0' || cfc > '9')
                    throw new Exception("Bogus content length");

                contentLength *= 10;
                contentLength += (int)fc - (int)'0';
            }
        }
        
        action leave_header_value {
            //Console.WriteLine("leave_header_value fpc " + fpc + " fc " + (char)fc);
            parser.OnHeaderValue(this, new ArraySegment<byte>(data, mark, fpc - mark));
        }

        action leave_headers {
			Console.WriteLine("leave_headers contentLength = " + contentLength);
            parser.OnHeadersEnd(this);

			// if chunked transfer, ignore content length and parse chunked (but we can't yet so bail)
			// if content length given but zero, read next request
			// if content length is given and non-zero, we should read that many bytes
			// if content length is not given
			//   if should keep alive, assume next request is coming and read it
			//   else read body until EOF

			if (contentLength == 0)
			{
				parser.OnMessageEnd(this);
				fhold;
				fgoto main;
			}
			else if (contentLength > 0)
			{
				fgoto body_identity;
			}
			else
			{
				Console.WriteLine("Request had no content length.");
				if (ShouldKeepAlive)
				{
					parser.OnMessageEnd(this);
					Console.WriteLine("Should keep alive, will read next message.");
					fhold;
					fgoto main;
				}
				else
				{
					Console.WriteLine("Not keeping alive, will read until eof. Will hold, but currently fpc = " + fpc);
					fhold;
					fgoto body_identity_eof;
				}
			}
        }

		action eof_leave_body_identity {
			var toRead = Math.Min(pe - p, contentLength);
			if (toRead > 0)
			{
				parser.OnBody(this, new ArraySegment<byte>(data, p, toRead));
				p += toRead - 1;
				contentLength -= toRead;

				if (contentLength == 0)
				{
					parser.OnMessageEnd(this);

					if (ShouldKeepAlive)
						fret;
					else
					{
						fhold;
						fgoto dead;
					}
				}
			}
		}
		
		action eof_leave_body_identity_eof {
			Console.WriteLine("eof_leave_body_identity_eof");
			var toRead = pe - p;
			if (toRead > 0)
			{
				parser.OnBody(this, new ArraySegment<byte>(data, p, toRead));
				p += toRead - 1;
			}
			else
			{
				parser.OnMessageEnd(this);
				
				if (ShouldKeepAlive)
					fgoto main;
				else
				{
					fhold;
					fgoto dead;
				}
			}
		}

		action enter_dead {
			throw new Exception("Parser is dead; there shouldn't be more data. Client is bogus? fpc =" + fpc);
		}

		action in_body_identity_eof {
			Console.WriteLine("in_body_identity_eof");
		}

        include http "http.rl";
        
        }%%
        
        %% write data;
        
        public HttpParser(IHttpParserHandler parser)
        {
            this.parser = parser;
            %% write init;
        }

        public int Execute(ArraySegment<byte> buf)
        {
            byte[] data = buf.Array;
            int p = buf.Offset;
            int pe = buf.Offset + buf.Count;
            //int eof = pe == 0 ? 0 : -1;
            int eof = pe;
            mark = 0;
            qsMark = 0;
            fragMark = 0;
            
			if (p == pe)
				Console.WriteLine("Parser executing on p == pe (EOF)");

            %% write exec;
            
            var result = p - buf.Offset;

			if (result != buf.Count)
			{
				Console.WriteLine("error on character " + p);
				Console.WriteLine("('" + buf.Array[p] + "')");
				Console.WriteLine("('" + (char)buf.Array[p] + "')");
			}

			return p - buf.Offset;
        }
    }
}
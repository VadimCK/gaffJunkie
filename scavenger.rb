#!/usr/bin/env ruby

require 'daybreak'
require 'httparty'
require 'json'
require 'mail'
require 'erb'


class ZillowList
    include HTTParty

    def self.fetch
        resp = self.get('http://www.zillow.com/search/GetResults.htm?spt=homes&status=000010&lt=000000&ht=111101&pr=,860141&mp=,3000&bd=2%2C&ba=1.5%2C&sf=900,&parking=0&laundry=0&sch=100111&zoom=14&rect=-122360036,47599652,-122311928,47626558&p=1&search=maplist')
        throw "[ERROR] failed to pull listings" unless resp.code == 200
        JSON.parse(resp.body)['map']['properties']
    end

end

class ZillowDetails
    attr_accessor :title, :address

    def initialize(zpid)
        path = "http://www.zillow.com/jsonp/Hdp.htm?zpid=%d&fad=false&hc=false&lhdp=true&callback=YUI.Env.JSONP.handleHomeDetailPage%d&view=null&ebas=true" % [zpid, zpid]
        resp = HTTParty.get(path)

        #Abstract the JS object passed into handleHomeDetailPage()
        parsed_object = /handleHomeDetailPage#{zpid}\( ({.+})\);/.match(resp.body)[1]

        #Abstracted object isn't JSONy enough to be parsed like JSON... hacky regex it is.
        @title = /"subtitle" : "([^"]+)"/.match(parsed_object)[1]
        @address = /data-address=\\"([^"]+)\\"/.match(parsed_object)[1]

    end
end

class Property < ZillowDetails
    attr_accessor :zpid, :long, :lat, :rent, :bed, :bath, :sqft, :thumb

    def initialize(params)
        @zpid = params[0]
        @long = params[1].to_s.insert(-7, '.')
        @lat = params[2].to_s.insert(-7, '.')
        @rent = params[8][0]
        @beds = params[8][1]
        @bath = params[8][2]
        @sqft = params[8][3]
        @thumb = params[8][5]

        super(@zpid)
    end

    def zillow_url
      "http://zillow.com/homedetails/hax/%s_zpid/" % @zpid
    end

    def google_maps_url
      "http://maps.google.com/?q=%s,%s" % [@long, @lat]
    end
end

class PropertyStore
    def initialize(path)
        @db = Daybreak::DB.new path
    end

    def add(property)
        @db.set!(property.zpid, property)
    end

    def get(zpid)
        @db[zpid]
    end

    def has?(property)
        @db.has_key? property.zpid
    end

    def each
        @db.each do |zpid, p|
            yield zpid, p
        end
    end

    def close
        @db.flush
        @db.compact
        @db.close
    end

end

class PropertyNotifier
    def initialize(properties)
        @properties = properties
        @template = File.read(File.join(File.dirname(__FILE__), 'email.erb'))
    end

    def email_summary
        body = ERB.new(@template).result(binding)
        Mail.deliver do
            content_type 'text/html; charset=UTF-8'

            from    'gaffjunkie@domain.com'
            to      ['to@domain.com']
            subject '[gaffJunkie] New properties available!'
            body    body

            delivery_method :sendmail
        end
    end

end

store = PropertyStore.new File.join(File.dirname(__FILE__), 'property.db')
new_properties = []

ZillowList.fetch.each do |entry|
    p = Property.new entry
    unless store.has? p
      new_properties << p
      store.add p
    end
end

if new_properties.length > 0
  notify = PropertyNotifier.new new_properties
  notify.email_summary
end

store.close

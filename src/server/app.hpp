#pragma once
#include "auth.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/ssl.hpp>
#include <memory>

namespace net=boost::asio;
namespace beast=boost::beast;
namespace http=beast::http;
namespace websocket=beast::websocket;
using tcp=net::ip::tcp;
using namespace esport;
struct App {
    Store store;
    Auth auth;
    net::thread_pool passwordWorkers{2};
    std::string epoch=secureToken(16), token, apiToken, instance="dcs-local";
    std::uint64_t connectionNumber=0, ingressNumber=0, errors=0, frames=0;
    std::map<std::string,std::string> owners;
    std::size_t connections=0, webConnections=0, httpConnections=0, ingressConnections=0;
    j::array sources(const User& user) {
        j::array result;
        for(auto& value:store.summaries())if(user.allows(obj(field(obj(value),"source"))))result.push_back(std::move(value));
        return result;
    }
};

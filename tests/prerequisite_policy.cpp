#include "../tools/installer/prerequisite.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace prerequisite;
    int cases=0;
    for(auto existing:{528040u,528049u,533320u,534296u}) {
        int calls=0;auto r=ensure([&]{return existing;},[&]{++calls;return 1603u;});
        assert(r.state==State::ready&&!r.installed&&calls==0);++cases;
    }
    for(auto old:{0u,461808u,528039u}) {
        int calls=0,reads=0;auto r=ensure([&]{return ++reads==1?old:528049u;},[&]{++calls;return 0u;});
        assert(r.state==State::ready&&r.installed&&calls==1&&reads==2);++cases;
    }
    for(auto code:{3010u,1641u}) {
        int reads=0;auto r=ensure([&]{++reads;return 0u;},[&]{return code;});
        assert(r.state==State::restart_required&&r.code==code&&reads==1);++cases;
    }
    for(auto code:{1602u,1223u}) {
        auto r=ensure([]{return 0u;},[&]{return code;});assert(r.state==State::cancelled&&r.code==code);++cases;
    }
    for(auto code:{1603u,1618u,5100u}) {
        auto r=ensure([]{return 0u;},[&]{return code;});assert(r.state==State::failed&&r.code==code);++cases;
    }
    auto absent=ensure([]{return 0u;},[]{return 0u;});assert(absent.state==State::not_detected);++cases;
    std::cout<<cases<<" prerequisite policy cases passed\n";
}

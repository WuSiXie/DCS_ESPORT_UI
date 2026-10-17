#pragma once
#include <cstdint>

namespace prerequisite {
constexpr std::uint32_t minimum_release = 528040;
enum class State { ready, restart_required, cancelled, failed, not_detected };
struct Result { State state; std::uint32_t code; bool installed; };

// Shared by the native bootstrap and isolated tests; never modifies registry itself.
template<class Detect,class Install> Result ensure(Detect detect,Install install) {
    if(detect() >= minimum_release) return {State::ready,0,false};
    const auto code=install();
    if(code==3010 || code==1641) return {State::restart_required,code,true};
    if(code==1602 || code==1223) return {State::cancelled,code,false};
    if(code!=0) return {State::failed,code,false};
    if(detect()<minimum_release) return {State::not_detected,1603,true};
    return {State::ready,0,true};
}
}

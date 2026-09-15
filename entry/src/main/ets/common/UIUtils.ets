import { deviceInfo } from "@kit.BasicServicesKit";
import { uiMaterial } from "@kit.ArkUI";

export function getMenuOptions(): MenuOptions{
  if(deviceInfo.apiAvailable('26.0.0')){
    return {
      systemMaterial:new uiMaterial.ImmersiveMaterial({
        style:uiMaterial.ImmersiveStyle.THICK
      })
    };
  }else{
    return {};
  }
}
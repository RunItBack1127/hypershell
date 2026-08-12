package roleBindings

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/gorilla/mux"

	"github.com/openshift-online/hypershell/components/api-server/pkg/api/openapi"
	"github.com/openshift-online/hypershell/components/api-server/pkg/rbac"
	"github.com/openshift-online/rh-trex-ai/pkg/api/presenters"
	"github.com/openshift-online/rh-trex-ai/pkg/errors"
	"github.com/openshift-online/rh-trex-ai/pkg/handlers"
	"github.com/openshift-online/rh-trex-ai/pkg/services"
)

type roleBindingHandler struct {
	roleBinding   RoleBindingService
	generic       services.GenericService
	bindingLookup rbac.RoleBindingLookup
}

func NewRoleBindingHandler(roleBinding RoleBindingService, generic services.GenericService, bindingLookup rbac.RoleBindingLookup) *roleBindingHandler {
	return &roleBindingHandler{
		roleBinding:   roleBinding,
		generic:       generic,
		bindingLookup: bindingLookup,
	}
}

func (h roleBindingHandler) Create(w http.ResponseWriter, r *http.Request) {
	var rb openapi.RoleBinding
	cfg := &handlers.HandlerConfig{
		Body: &rb,
		Validators: []handlers.Validate{
			handlers.ValidateEmpty(&rb, "Id", "id"),
		},
		Action: func() (interface{}, *errors.ServiceError) {
			ctx := r.Context()
			rbModel := ConvertRoleBinding(rb)
			rbModel, err := h.roleBinding.Create(ctx, rbModel)
			if err != nil {
				return nil, err
			}
			return PresentRoleBinding(rbModel), nil
		},
		ErrorHandler: handlers.HandleError,
	}

	handlers.Handle(w, r, cfg, http.StatusCreated)
}

func (h roleBindingHandler) List(w http.ResponseWriter, r *http.Request) {
	cfg := &handlers.HandlerConfig{
		Action: func() (interface{}, *errors.ServiceError) {
			ctx := r.Context()

			listArgs := services.NewListArguments(r.URL.Query())

			if scopeErr := h.applyScopeFilter(ctx, listArgs); scopeErr != nil {
				return nil, scopeErr
			}

			var bindings []RoleBinding
			paging, err := h.generic.List(ctx, "id", listArgs, &bindings)
			if err != nil {
				return nil, err
			}
			kindStr := "RoleBindingList"
			pageVal := int32(paging.Page)
			sizeVal := int32(paging.Size)
			totalVal := int32(paging.Total)
			rbList := openapi.RoleBindingList{
				Kind:  &kindStr,
				Page:  &pageVal,
				Size:  &sizeVal,
				Total: &totalVal,
				Items: []openapi.RoleBinding{},
			}

			for _, binding := range bindings {
				converted := PresentRoleBinding(&binding)
				rbList.Items = append(rbList.Items, converted)
			}
			if listArgs.Fields != nil {
				filteredItems, err := presenters.SliceFilter(listArgs.Fields, rbList.Items)
				if err != nil {
					return nil, err
				}
				return filteredItems, nil
			}
			return rbList, nil
		},
	}

	handlers.HandleList(w, r, cfg)
}

func (h roleBindingHandler) Get(w http.ResponseWriter, r *http.Request) {
	cfg := &handlers.HandlerConfig{
		Action: func() (interface{}, *errors.ServiceError) {
			id := mux.Vars(r)["id"]
			ctx := r.Context()
			rb, err := h.roleBinding.Get(ctx, id)
			if err != nil {
				return nil, err
			}

			return PresentRoleBinding(rb), nil
		},
	}

	handlers.HandleGet(w, r, cfg)
}

func (h roleBindingHandler) Delete(w http.ResponseWriter, r *http.Request) {
	cfg := &handlers.HandlerConfig{
		Action: func() (interface{}, *errors.ServiceError) {
			id := mux.Vars(r)["id"]
			ctx := r.Context()
			err := h.roleBinding.Delete(ctx, id)
			if err != nil {
				return nil, err
			}
			return nil, nil
		},
	}
	handlers.HandleDelete(w, r, cfg, http.StatusNoContent)
}

func (h roleBindingHandler) applyScopeFilter(ctx context.Context, args *services.ListArguments) *errors.ServiceError {
	if h.bindingLookup == nil {
		return nil
	}

	userID := rbac.GetUserIDFromContext(ctx)
	if userID == "" {
		return nil
	}

	bindings, err := h.bindingLookup.FindBindingsByUserID(ctx, userID)
	if err != nil {
		return errors.GeneralError("unable to resolve role_binding scope: %v", err)
	}

	for _, b := range bindings {
		if b.RoleName == "gateway:creator" {
			return nil
		}
	}

	scopeFilter := fmt.Sprintf("user_id = '%s'", strings.ReplaceAll(userID, "'", "''"))
	if args.Search != "" {
		args.Search = fmt.Sprintf("(%s) and %s", args.Search, scopeFilter)
	} else {
		args.Search = scopeFilter
	}
	return nil
}
